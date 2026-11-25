# nft_fullcone_optimize

`nft-fullcone`（nftables fullcone NAT 表达式）的高 CPU 占用修复，附带一个可重复执行的安装脚本。

> **TL;DR** — `nft_fullcone` 对**每一个包**都会抢全局自旋锁、遍历 mapping 哈希表，并且对已确认连接也执行一次 `kmalloc()` + 链表插入。高并发 NAT（PCDN / BT / 大流量 UDP，几千到上万条流）时这把锁成为瓶颈，软中断被拉长到毫秒级。补丁让已确认连接直接返回：IPQ60xx 实测总 CPU **41.4% → 19.9%**，软中断 **1.32 → 0.47 核**（吞吐还略有上升），fullcone 语义不变。

---

## 问题

`nf_nat_fullcone.c` 中的 `nf_nat_handle_prerouting()` 和 `nf_nat_handle_postrouting()` 由 nftables 的 `fullcone` 表达式在每个包上调用（fw4 生成的规则没有 `ct state` 限定）：

```c
ct = nf_ct_get(skb, &ctinfo);
...
spin_lock_bh(&fullconenat_lock);            /* 全局锁，所有 CPU 共享 */
mapping = get_mapping_by_ext_port(...);     /* 1024 桶全局哈希表遍历 */
...
ret = nf_nat_setup_info(ct, newrange, ...); /* 对 confirmed ct 立即返回 NF_ACCEPT */
if (ret == NF_ACCEPT)
    add_original_tuple_to_mapping(mapping, ct_tuple_origin);
                                            /* 每包 kmalloc + list_add */
```

几个叠加的问题：

1. **全局自旋锁**：4 个 CPU 处理转发包时抢同一把锁，CPU 时间大量花在自旋上，单次软中断被拉长到几毫秒甚至几十毫秒。
2. **对已确认连接做无用功**：内核 `nf_nat_setup_info()` 第一行就是 `if (nf_ct_is_confirmed(ct)) return NF_ACCEPT;`，所以查表、加锁之后的 NAT 设置实际上什么都没做。
3. **每包一次原子分配**：`add_original_tuple_to_mapping()` 无条件 `kmalloc(sizeof(struct nat_mapping_original_tuple), GFP_ATOMIC)` 并插入链表。
4. **映射表泄漏**：连接销毁时 `nf_nat_fullcone_handle_dying_tuples()` 只删除 **1 条** tuple，而运行时每条连接插入了 N 条（每个包一条）。`refer_count` 永远降不到 0，mapping 永远不会释放，哈希链越跑越长 —— 也就是**开机越久 CPU 越高**。

## 修复

在 `nf_nat_handle_prerouting()` 和 `nf_nat_handle_postrouting()` 里，conntrack 已确认时直接返回：

```c
if (nf_ct_is_confirmed(ct))
    return ret;
```

理由：已确认连接的后续包由 conntrack NAT 核心处理，`nf_nat_setup_info()` 本来就不会做事；fullcone 的映射建立/查找只需要在连接的第一个包上执行一次。补丁同时对 IPv4 / IPv6 生效。

### 为什么不用 `ct state new`

给 fw4 规则加 `ct state new` 看起来更简单，但实测**无效**：`ct state new` 在 nftables 里是「`IPS_SEEN_REPLY` 未置位」，而 PCDN 大量单向 UDP 流永远收不到回包，于是每个包都仍然是 NEW。必须在模块里用 `nf_ct_is_confirmed()` 才能真正做到「每个连接一次」。

## 实测

设备：IPQ60xx（4×Cortex-A53 @1.8GHz，OpenWrt 25.12 / Linux 6.12，NSS 硬件加速，1.3~1.5 万条 PCDN UDP 并发流）。

15 秒窗口，同一时段对比（流量单位为 lan1 双向合计）：

| 场景 | 总 CPU | sirq | 吞吐 | 归一化（核/10 万 pps） |
|---|---|---|---|---|
| 原版 fullcone | 41.4%（1.66 核） | 32.9%（1.32 核） | 47.6k pps / 28.9 MB/s | 53.5 |
| 关闭 fullcone（对照） | 11.8% | 4.4% | 40.4k pps | 17.1 |
| **打补丁后** | **19.9%（0.80 核）** | **11.8%（0.47 核）** | 47.8k pps / 31.5 MB/s | **24.4** |

打补丁后 fullcone 仍启用，NAT 行为验证正常（conntrack 里可见 SNAT 到 WAN 地址、无内核报错）。

## 使用

在 OpenWrt / ImmortalWrt 源码树根目录：

```sh
# 安装补丁（自动定位 package/network/utils/fullconenat-nft）
./nft_fullcone_optimize.sh

# 安装并立即编译 kmod-nft-fullcone
./nft_fullcone_optimize.sh --build

# 只看看会做什么
./nft_fullcone_optimize.sh --dry-run

# 卸载
./nft_fullcone_optimize.sh --revert
```

脚本是幂等的：重复执行不会重复自增 `PKG_RELEASE`。包不在默认位置时用 `--package-dir` 指定。

也可以直接手工应用补丁到 nft-fullcone 源码（路径前缀 `a/src/`、`b/src/`）：

```sh
patch -p1 -d /path/to/nft-fullcone-2023.05.17~07d93b62 < 020-skip-confirmed-conntrack.patch
```

## 兼容性

- 针对 `nft-fullcone` `2023.05.17~07d93b62`（OpenWrt 23.05 / 24.10 / 25.x 使用的版本）编写。
- 补丁只依赖 `nf_ct_is_confirmed()`，与内核版本无关；已在 Linux 6.12 上验证。
- 源码版本不同导致补丁无法应用时，脚本会给出警告，可手工按上面两处上下文插入。

## 注意事项

- 热替换运行中的模块需要先让 nftables 规则不再引用 `fullcone`（改 uci + `fw4 reload` + `rmmod`），脚本结尾打印了完整步骤。
- 本补丁只减少开销，不改变映射/端口分配策略，因此 NAT 类型（fullcone）行为与原来一致。
- 如果只想彻底避免这部分开销，也可以直接关闭 fullcone（`firewall.@defaults[0].fullcone=0`），但 PCDN 等场景通常需要 fullcone 提升 NAT 类型。

## License

GPL-2.0-only（与上游 nft-fullcone 一致）。