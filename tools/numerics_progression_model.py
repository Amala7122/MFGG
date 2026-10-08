# -*- coding: utf-8 -*-
"""数值模型：武器成长闭环（等级曲线 + 模块独立倍率 + 出怪反馈环）。

复刻的真实代码路径：
  player_weapon.gd:1079-1091 get_bullet_damage()  = curve(L) * get_damage_multiplier()
  player_weapon.gd:879-883  get_primary_shots_per_second()
                                                  = sps * level_bonus(L) * get_fire_rate_multiplier()
  player_weapon.gd:999-1002 get_fire_rate_multiplier() = 1 + stacks*0.08
  player_weapon.gd:1009-1012 get_damage_multiplier()   = 1 + stacks*0.10
  player_weapon.gd:1088-1089 linear segment: late_base + (L - (size+1)) * late_per_level
  player_weapon.gd:952-968  apply_upgrade(): 每个模块层 -> _weapon_level += 1
  wave_director.gd:389-396  _count_for_wave(): n = base + growth*(w-1) + 7*max(L-4,0)
  wave_director.gd:309-312  第 count+1 次进入 -> Boss
  run_state.gd:72-86        换图 -> 武器等级与模块清零（赐福不清）
  pickup.gd:45-66           roll_drop(): 先掷掉落率，再按权重抽类型

历史公式参考，输出到项目外本次运行 reports/numerics_model_output.txt
"""
import json, os, random, statistics, io
import sys
from pathlib import Path
from artifact_paths import create_run
sys.stdout.reconfigure(encoding="utf-8")

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = str(Path(HERE).parent)
CFG = json.load(open(os.path.join(ROOT, "data", "game_config.json"), encoding="utf-8"))

W = CFG["weapon"]
ROSTER = CFG["enemy_roster"]
SPAWN = CFG["spawn"]
DROPS = CFG["drops"]
DR_KEYS = list(DROPS["weights"].keys())
DR_W = [float(DROPS["weights"][k]) for k in DR_KEYS]
DR_TOTAL = sum(DR_W)
MODULES = ("fire_rate", "damage", "magazine")
MAX_STACKS = {k: int(W["upgrades"][k]["max_stacks"]) for k in MODULES}
PER_STACK = {k: float(W["upgrades"][k].get("per_stack", 0.0)) for k in ("fire_rate", "damage")}

buf = io.StringIO()
def p(s=""):
    buf.write(str(s) + "\n")

def hr(ch="=", n=96):
    p(ch * n)


# ---------------------------------------------------------------- 武器曲线

def level_rate_bonus(L):
    return min(1.0 + (L - 1) * W["fire_rate_bonus_per_level"], W["fire_rate_bonus_max"])


def curve_damage(L):
    """player_weapon.gd:1079-1091，不含模块倍率。"""
    per = W["bullet_damage"]["per_level"]
    if L <= len(per):
        return float(per[L - 1])
    late_start = len(per) + 1
    return W["bullet_damage"]["late_base"] + (L - late_start) * W["bullet_damage"]["late_per_level"]


def damage_mult(st_dmg):
    return 1.0 + st_dmg * PER_STACK["damage"]


def fire_mult(st_fr):
    return 1.0 + st_fr * PER_STACK["fire_rate"]


def curve_dps(L):
    """纯等级曲线（= 数值验收基线 的口径）。"""
    return W["shots_per_second"] * level_rate_bonus(L) * curve_damage(L)


def real_dps(L, st_fr, st_dmg):
    """实际 DPS = 等级曲线 x 射速模块 x 威力模块。"""
    return (W["shots_per_second"] * level_rate_bonus(L)
            * curve_damage(L) * fire_mult(st_fr) * damage_mult(st_dmg))


# ---------------------------------------------------------------- 敌人

def entries_for(L):
    return [e for e in ROSTER["entries"] if float(e["min_weapon_level"]) <= L]


def ranged_ratio(L):
    es = entries_for(L)
    return sum(1 for e in es if e["kind"] == "ranged") / len(es) if es else 0.0


def enemy_hp(e, L):
    if e["kind"] == "ranged":
        base = W["ranged_shot_tiers"][int(e["health_tier"])] * W["sniper_base_damage"] * W["ranged_health_margin"]
        return base * (1.0 + (L - 1) * W["sniper_growth_per_level"])
    return float(e["health"]) * (1.0 + L * ROSTER["health_growth_per_level"])


def avg_hp(L):
    es = entries_for(L)
    return sum(enemy_hp(e, L) for e in es) / len(es)


def drop_chance(L):
    r = ranged_ratio(L)
    return DROPS["melee_chance"] * (1 - r) + DROPS["ranged_chance"] * r


def p_module():
    return sum(w for k, w in zip(DR_KEYS, DR_W) if k in MODULES) / DR_TOTAL


# ---------------------------------------------------------------- 表一：曲线

p("数值模型输出 —— 由 _analysis/numerics_progression_model.py 生成")
p("数据来源: godot-ruin_star_new/data/game_config.json")
hr()
p("表一  武器曲线：纸面等级曲线 vs 实际（含模块独立倍率）")
hr()
p(f"{'L':>3} {'射速(等级)':>10} {'单发':>8} {'纸面DPS':>9} {'相对L1':>7} | "
  f"{'满射速模块':>10} {'满威力模块':>10} {'两者都满':>10} {'实际/纸面':>9}")
p("-" * 96)
d1 = curve_dps(1)
rows = []
for L in range(1, 26):
    cd = curve_dps(L)
    fr = fire_mult(MAX_STACKS["fire_rate"])
    dm = damage_mult(MAX_STACKS["damage"])
    full = cd * fr * dm
    rows.append((L, cd, full))
    p(f"{L:>3} {W['shots_per_second']*level_rate_bonus(L):>10.2f} {curve_damage(L):>8.1f} "
      f"{cd:>9.1f} {cd/d1:>6.2f}x | {cd*fr:>10.1f} {cd*dm:>10.1f} {full:>10.1f} {full/cd:>8.2f}x")

p()
p("※ 关键：模块层数【双重生效】—— player_weapon.gd:962 每层 +1 武器等级（抬上面这条曲线），")
p("  同时 get_fire_rate_multiplier / get_damage_multiplier 再乘一次。")
p(f"  满配额外乘数 = (1+{MAX_STACKS['fire_rate']}x{PER_STACK['fire_rate']}) x "
  f"(1+{MAX_STACKS['damage']}x{PER_STACK['damage']}) = "
  f"{fire_mult(MAX_STACKS['fire_rate']):.2f} x {damage_mult(MAX_STACKS['damage']):.2f} = "
  f"{fire_mult(MAX_STACKS['fire_rate'])*damage_mult(MAX_STACKS['damage']):.2f}x")
p("  而 docs/数值验收基线.md 的『净杀伤效率 ≤ 2.0』门槛只算纸面曲线，不含这一项。")

# ---------------------------------------------------------------- 表二：净效率

p()
hr()
p("表二  净杀伤效率：验收基线口径 vs 实际口径")
hr()
p(f"{'L':>3} {'纸面DPS倍数':>11} {'血量倍数':>9} {'基线净效率':>11} | "
  f"{'实际DPS倍数':>11} {'实际净效率':>11} {'超出基线':>9}")
p("-" * 96)
p("血量倍数 = 平均血(L)/平均血(1)，含图鉴随等级解锁新敌人的成分")
h1 = avg_hp(1)
for L in (1, 4, 7, 10, 12, 16, 20, 25):
    st_fr = min(MAX_STACKS["fire_rate"], max(0, L - 1))
    st_dmg = min(MAX_STACKS["damage"], max(0, L - 1 - st_fr))
    cd = curve_dps(L)
    rd = real_dps(L, st_fr, st_dmg)
    h = avg_hp(L)
    base_net = (cd / d1) / (h / h1)
    real_net = (rd / real_dps(1, 0, 0)) / (h / h1)
    p(f"{L:>3} {cd/d1:>10.2f}x {h/h1:>8.2f}x {base_net:>10.2f} | "
      f"{rd/real_dps(1,0,0):>10.2f}x {real_net:>10.2f} {real_net/base_net:>8.2f}x")

p()
p("※ 基线口径与『一个敌人按同系数变肉』同构；实际口径还含两件事：")
p("  ① 图鉴随等级解锁更肉的条目（L1 只有 3 条、L4 有 15 条），平均血涨得比成长系数快；")
p("  ② 模块的独立倍率。")

# ---------------------------------------------------------------- 表三：出怪反馈环

p()
hr()
p("表三  出怪反馈环（wave_director.gd:389-396）")
hr()
p(f"    n(波) = base + growth x (波-1) + {SPAWN['extra_enemies_per_level']} x max(武器等级 - "
  f"{SPAWN['threat_level_offset']}, 0)")
p("    武器等级由【掉落模块】驱动 -> 杀得越多 -> 等级越高 -> 出怪越多 -> 杀得越多")
p()

def simulate(arena_id, pickup_rate, seed=11, trials=4000):
    a = CFG["arenas"]["definitions"][arena_id]
    wc = a["wave"]
    cnt, base, growth = int(wc["count"]), float(wc["base_enemies"]), float(wc["growth_per_wave"])
    ex, off = float(SPAWN["extra_enemies_per_level"]), float(SPAWN["threat_level_offset"])
    si = float(SPAWN["spawn_interval"])
    rng = random.Random(seed)
    ends, kills_, waves0 = [], [], None
    for _ in range(trials):
        L, st = 1, {k: 0 for k in MODULES}
        tot, ws = 0, []
        for w in range(1, cnt + 1):
            n = max(round(base + growth * (w - 1) + ex * max(L - off, 0.0)), 1)
            kill_rate = real_dps(L, st["fire_rate"], st["damage"]) / max(avg_hp(L), 1e-6)
            spawn_rate = 1.0 / si
            ws.append((w, L, n, min(kill_rate, spawn_rate), kill_rate > spawn_rate))
            for _ in range(n):
                tot += 1
                if rng.random() >= drop_chance(L) * pickup_rate:
                    continue
                roll, acc, pick = rng.random() * DR_TOTAL, 0.0, None
                for k, wt in zip(DR_KEYS, DR_W):
                    acc += wt
                    if roll <= acc:
                        pick = k
                        break
                if pick in MODULES and st[pick] < MAX_STACKS[pick]:
                    st[pick] += 1
                    L += 1
        ends.append(L); kills_.append(tot)
        if waves0 is None:
            waves0 = ws
    boss = float(CFG["bosses"][wc["boss_id"]]["health"])
    return dict(waves=waves0, level=statistics.mean(ends), kills=statistics.mean(kills_),
                boss_hp=boss, boss_ttk=boss / real_dps(int(statistics.mean(ends)),
                                                       min(MAX_STACKS["fire_rate"], int(statistics.mean(ends)) - 1),
                                                       min(MAX_STACKS["damage"],
                                                           max(0, int(statistics.mean(ends)) - 1 - MAX_STACKS["fire_rate"]))))

for pr in (1.0, 0.75, 0.5):
    for aid in CFG["arenas"]["order"]:
        a = CFG["arenas"]["definitions"][aid]
        r = simulate(aid, pr)
        p(f"[{aid} / {a['label']}]  拾取率 {pr:.0%}   (wave.count={a['wave']['count']}, "
          f"base={a['wave']['base_enemies']}, growth={a['wave']['growth_per_wave']})")
        p(f"  {'波':>2} {'起始L':>6} {'敌人数':>7} {'有效清场/秒':>11} {'瓶颈':>6}")
        for (w, L, n, rate, spawn_lim) in r["waves"]:
            p(f"  {w:>2} {L:>6} {n:>7} {rate:>11.2f} {'出怪' if spawn_lim else '击杀':>6}")
        p(f"  -> 波次敌人合计 {sum(x[2] for x in r['waves'])}  结束等级 {r['level']:.1f}  "
          f"累计击杀 {r['kills']:.0f}")
        p(f"  -> Boss {r['boss_hp']:.0f} 血, TTK {r['boss_ttk']:.1f}s")
        p()

# ---------------------------------------------------------------- 表四：掉落经济

hr()
p("表四  掉落经济")
hr()
p(f"  权重: " + "  ".join(f"{k}={int(v)}" for k, v in DROPS["weights"].items()) + f"  (总 {DR_TOTAL:.0f})")
p(f"  概率: 模块 {p_module():.1%} | 弹药 {DROPS['weights']['ammo']/DR_TOTAL:.1%} | "
  f"生命 {DROPS['weights']['health']/DR_TOTAL:.1%}")
p(f"  掉落率: 近战 {DROPS['melee_chance']:.2f} / 远程 {DROPS['ranged_chance']:.2f}；"
  f"L1 远程占比 {ranged_ratio(1):.1%} -> 综合 {drop_chance(1):.3f}")
p(f"  模块上限 {MAX_STACKS} -> 武器等级上限 {1+sum(MAX_STACKS.values())}")
p(f"  每杀期望模块层数 (拾取率100%) = {drop_chance(1)*p_module()*1.0:.4f}")
p(f"  每杀期望模块层数 (拾取率 75%) = {drop_chance(1)*p_module()*0.75:.4f}")

# ---------------------------------------------------------------- 表五

hr()
p("表五  Boss 需求血量 与 关卡时长预算")
hr()
boss_cfg = CFG["bosses"]["warden"]
bh = float(boss_cfg["health"])
p(f"  当前 Boss({boss_cfg['behavior']}) health = {bh:.0f}  (bosses.warden.health，常量、不随等级缩放)")
p(f"  弱点倍率 x{float(boss_cfg['weak_point_multiplier'])} / 弱点占比 {float(boss_cfg['weak_point_ratio'])}")
p()
p(f"  {'玩家状态':>22} {'实际DPS':>9} {'Boss TTK':>9} | {'要 30s 需血量':>13} {'要 60s 需血量':>13}")
p("  " + "-" * 74)
scen = [
    ("L1 无模块 (开局)", 1, 0, 0),
    ("L1 满模块", 1, 8, 8),
    ("L6 约 2+3 模块", 6, 2, 3),
    ("L11 50%拾取率收尾", 11, 8, 2),
    ("L12 验收基线终点", 12, 0, 0),
    ("L12 满模块", 12, 8, 8),
    ("L20 100%拾取率收尾", 20, 8, 8),
    ("L23 100%拾取率均值", 23, 8, 8),
]
for name, L, fr, dm in scen:
    d = real_dps(L, fr, dm)
    p(f"  {name:>22} {d:>9.0f} {bh/d:>8.1f}s | {d*30:>13.0f} {d*60:>13.0f}")
p()
p("  ※ 无论哪一档，Boss 都在 0.5~19 秒内死。Boss 血量是常量而 DPS 涨了 34 倍。")

p()
p("  关卡时长预算（sanctum，4 波 + Boss）")
p("  " + "-" * 74)
a = CFG["arenas"]["definitions"]["sanctum"]
wc = a["wave"]
inter = float(wc["intermission"])
cin = 2.2
p(f"    intermission = {inter:.0f}s x {int(wc['count'])-1} 次 = {inter*(int(wc['count'])-1):.0f}s")
p(f"    波次肃清特写 = {cin:.1f}s x {int(wc['count'])} 次 = {cin*int(wc['count']):.0f}s")
p(f"    出怪时间     = 总敌人数 / (1/{float(SPAWN['spawn_interval']):.2f})  —— 见表三")
p(f"    Boss 战      = 0.5~19s（见表五）")
p(f"    合计(100%拾取, 124 敌) ≈ {124/ (1/float(SPAWN['spawn_interval'])) + inter*3 + cin*4:.0f}s 不含玩家跑位")
p()
p("  ※ 所有波次的有效清场速率都被【出怪速率 1.18/s】卡住（表三 瓶颈列全为『出怪』），")
p("    所以玩家 DPS 从 140 涨到 4800（34 倍）【并不缩短关卡】—— 它只降低挨打时长。")
p("    出怪节拍与玩家强度是解耦的：节奏旋钮 = spawn_interval / max_alive，")
p("    强度旋钮只作用在受击压力上。")

hr()
p("表六  强度等价单位 PU（Power Unit）—— 把一切都换算到同一把尺子上")
hr()
PU = curve_dps(1)          # L1 无模块 1 秒的纸面输出
p(f"  定义：1 PU = {PU:.0f} 点伤害 = L1 玩家 1 秒的纸面输出")
p(f"  用途：任何数值（血量/伤害/爆发/治疗）除以 {PU:.0f} 就得到『等于 L1 玩家打几秒』。")
p()
p(f"  {'对象':<34} {'点伤害':>10} {'PU':>8} {'= L1 打几秒':>12}")
p("  " + "-" * 68)
_res = CFG["resonance"]
abilities = CFG["abilities"]
items = [
    ("近战士兵 血 @L1", 90.0 * (1 + 1 * ROSTER["health_growth_per_level"])),
    ("重装战士 血 @L1", 210.0 * (1 + 1 * ROSTER["health_growth_per_level"])),
    ("巨型破坏者 血 @L1", 520.0 * (1 + 1 * ROSTER["health_growth_per_level"])),
    ("巨型破坏者 血 @L12", 520.0 * (1 + 12 * ROSTER["health_growth_per_level"])),
    ("手雷 单发", float(abilities["grenade"]["damage"])),
    ("震地脉冲 单发", float(abilities["skill"]["damage"])),
    ("共鸣爆发 100% 蓄力", 520.0),
    ("共鸣爆发 200% 过载", 2400.0),
    ("Boss warden 总血", float(CFG["bosses"]["warden"]["health"])),
    ("生命包 回复", float(CFG["pickups"]["health"]["heal"])),
    ("一场(sanctum 68 敌)总血池", None),
]
a68 = sum(enemy_hp(CFG["enemy_roster"]["entries"][i], 1)
          for i in range(len(CFG["enemy_roster"]["entries"])))
for name, v in items:
    if v is None:
        # 4 波 11/15/19/23，按 L1 图鉴平均血估
        v = 68 * avg_hp(1)
    p(f"  {name:<34} {v:>10.0f} {v/PU:>8.1f} {v/PU:>11.2f}s")
p()
p("  ※ 关键对比：")
p(f"     Boss = {float(CFG['bosses']['warden']['health'])/PU:.1f} PU")
p(f"     玩家 L1 无模块 = 1.0 PU/秒  -> Boss TTK {float(CFG['bosses']['warden']['health'])/PU:.1f}s")
p(f"     玩家 L12 纸面 = {curve_dps(12)/PU:.2f} PU/秒 -> Boss TTK {float(CFG['bosses']['warden']['health'])/curve_dps(12):.1f}s")
p(f"     玩家 L25 满模块 = {real_dps(25, 8, 8)/PU:.1f} PU/秒 -> Boss TTK "
  f"{float(CFG['bosses']['warden']['health'])/real_dps(25,8,8):.1f}s")
p(f"     共鸣过载单发 = {2400.0/PU:.1f} PU = Boss 总血的 {2400.0/float(CFG['bosses']['warden']['health']):.1%}")
p()
p("  ※ 结论：Boss 血量(18.6 PU) 应当用『目标 TTK x 预期 PU/秒』反推，而不是拍一个常量。")

hr()
p("表七  生存侧：验收基线完全缺失的另一半")
hr()
PL = CFG["player"]
EN = CFG["enemy"]
ehp = float(PL["max_health"]) + float(PL["shield_max"])
iframe = float(PL["hit_invulnerability"])
p(f"  有效生命 EHP = max_health {PL['max_health']:.0f} + shield_max {PL['shield_max']:.0f} = {ehp:.0f}")
p(f"  受击无敌帧 hit_invulnerability = {iframe:.2f}s -> 受击频率上限 {1/iframe:.2f} 次/秒")
p(f"  护盾再生 {PL['shield_regen_rate']:.0f}/s，停火 {PL['shield_regen_delay']:.0f}s 后启动")
p(f"      -> 可持续承伤 = {PL['shield_max']:.0f} / ({PL['shield_regen_delay']:.0f} + "
  f"{PL['shield_max']/PL['shield_regen_rate']:.0f}) = "
  f"{PL['shield_max']/(PL['shield_regen_delay']+PL['shield_max']/PL['shield_regen_rate']):.1f} 点/秒")
p(f"  生命自愈 {PL['health_regen_rate']:.0f}/s，但 cap_ratio = {PL['health_regen_cap_ratio']} "
  f"-> 只能回到 {PL['max_health']*PL['health_regen_cap_ratio']:.0f} 点")
p(f"  【max_health 恒定 {PL['max_health']:.0f}，全等级不成长】")
p(f"  敌人伤害成长 damage_growth_per_level = {ROSTER['damage_growth_per_level']}"
  f" -> L12 时 x{1+12*ROSTER['damage_growth_per_level']:.2f}")
p(f"  近战折扣 melee_damage_scale = {EN['melee_damage_scale']}；攻击间隔 {EN['melee_attack_interval']}s")
p()

def melee_entries(L):
    return [e for e in entries_for(L) if e["kind"] == "melee"]

p(f"  {'L':>3} {'近战条目':>8} {'平均单击':>9} {'承伤上限/秒':>11} {'极限存活':>9} {'治疗收入/杀':>11}")
p("  " + "-" * 60)
heal_per_kill = drop_chance(1) * (DROPS["weights"]["health"] / DR_TOTAL) * float(CFG["pickups"]["health"]["heal"])
for L in (1, 2, 3, 4, 7, 10, 12, 16, 20, 25):
    mes = melee_entries(L)
    dmg = [float(e["damage"]) * (1 + L * ROSTER["damage_growth_per_level"]) * float(EN["melee_damage_scale"])
           for e in mes]
    avg_d = sum(dmg) / len(dmg)
    incoming = avg_d / iframe
    ttd = ehp / incoming
    p(f"  {L:>3} {len(mes):>8} {avg_d:>9.1f} {incoming:>11.1f} {ttd:>8.1f}s {heal_per_kill:>11.2f}")
p()
p("  ※ 承伤上限由【无敌帧】封顶：每秒最多挨 1/0.42 = 2.38 次。")
p("    所以生存曲线只跟『单次伤害』走 —— 而它涨 2.68 倍、玩家血量一动不动。")
p(f"  ※ 治疗收入 {heal_per_kill:.2f} 点/杀 x 68 杀 = {heal_per_kill*68:.0f} 点/图；")
p(f"    而一波承伤上限 21~85 点/秒 —— 治疗收入与承伤完全不在一个量级。")
p()
p("  对照：武器侧 vs 生存侧（都用 L1 归一）")
p("  " + "-" * 60)
p(f"  {'L':>3} {'输出倍数':>9} {'生存窗口':>9} {'净难度(生存/输出)':>17}")
ttd1 = ehp / (sum(float(e['damage']) * (1+1*ROSTER['damage_growth_per_level']) * float(EN['melee_damage_scale'])
                  for e in melee_entries(1)) / len(melee_entries(1)) / iframe)
for L in (1, 4, 7, 10, 12, 16, 20, 25):
    mes = melee_entries(L)
    avg_d = sum(float(e["damage"]) * (1 + L * ROSTER["damage_growth_per_level"]) * float(EN["melee_damage_scale"])
                for e in mes) / len(mes)
    ttd = ehp / (avg_d / iframe)
    out = real_dps(L, min(8, max(0, L - 1)), min(8, max(0, L - 1 - 8))) / real_dps(1, 0, 0)
    p(f"  {L:>3} {out:>8.2f}x {ttd/ttd1:>8.2f}x {(ttd1/ttd)/out:>16.2f}")
p()
p("  ※ 生存窗口随等级【缩小】；输出随等级【放大】。两者相乘才是真实难度。")
p("    基线只算了前一半，所以『净杀伤效率 1.77 = 难度可控』的结论不完整：")
p("    玩家变强 36.7 倍的同时，被挨打致死的时间缩短了约 3.9 倍。")

run = create_run(Path(ROOT), "numerics_model")
output = run / "reports" / "numerics_model_output.txt"
output.write_text("历史公式模型：不代表当前运行代码实测。\n\n" + buf.getvalue(), encoding="utf-8")
print("OK ->", output)
