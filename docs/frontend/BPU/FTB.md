# BPU 子模块 FTB

## 功能概述

FTB 暂存 FTB 项，为后续高级预测器提供更为精确的分支指令位置、类型等信息。FTB 模块内有一 FTBBank 模块负责 FTB 项的实际存储，模块 内使用了一块多路 SRAM 作为存储器。

### 请求接收

0 阶段时，FTB 模块向内部 FTBBank 发送读请求，其请求 pc 值为 s0 传入的 PC,。

数据读取与返回

在发送请求的下一拍也就是预测器的 1 阶段，将暂存从 FTB SRAM 中读出的多路信号。

再下一拍也就是预测器的 2 阶段，从暂存数据中根据各路的 tag 和实际请求时 tag 的匹配情况生成命中信号并在命中时选出命中 FTB 数据。若存在 hit 请求，则返回值为选出的 FTB 项及命中的路信息，若未 hit，则输出数据无意义。tag 为 PC 的 29 到 10 位。

FTBBank 模块读出的数据在 FTB 模块内作为 2 阶段的预测结果以组合逻辑连线形式在当拍传递给后续预测器，此外这一读出的结果还会被暂 存到 FTB 模块内，在 3 阶段作为预测结果再次以组合逻辑连线传递给后续预测器。若 FTB 命中，则读出的命中路编号也会作为 meta 信息在 s3 与命中信息、周期数一起传递给后续 FTQ 模块。

此外，若 FTB 项内存在 always taken 标志，则 2 阶段的预测结果中对应 br_taken_mask 也在本模块内拉高处理。

### 数据更新

收到 update 请求后，FTB 模块会根据 meta 信息中是否 hit 决定更新时机。若 meta 中显示 hit，则在本拍立刻更新，否则需要延迟 2 周期等待读出 FTB 内现有结果后才可更新。

在 FTBBank 内部，当存在更新请求时，该模块行为也因立即更新和推迟更新两情况而有所不同。立即更新时，FTBBank 内的 SRAM 写通道拉高，按照给定的信息完成写入。推迟更新时，FTBBank 首先收到一个 update 的读请求且优先级高于普通预测的读请求，而后下一拍读出数据 ，选出给定地址命中的路编码传递给外部 FTB 模块。而若这一拍未命中，则下一拍需要写入到分配的路中。路选取规则为，若所有路均已 写满，则使用替换算法（此处为伪 LRU，详见 ICache 文档）选取要替换的路，否则选取一空路。

### SRAM 规格

单 bank，512 set，4 way，使用单口 SRAM，无读保持，有上电复位。

20 bit tag，60 bit FTB 项。

其中 FTB 项

1 bit valid

20 bit br slot（4 bit offset，12 bit lower 2 bit tarStat, 1bit sharing, 1 bit valid）

28 bit tail slot (4 bit offset , 20 bit lower, 2 bit tarStat, 1 bit sharing, 1 bit valid)

4 bit pftAddr

1 bit carry

1 bit isCall

1 bit isRet

1 bit isJalr

1 bit 末尾可能为 rvi call

2 bit always taken

## 整体框图

![整体框图](../figure/BPU/FTB/structure.png)

## 接口时序

### 结果输出接口

![结果输出接口](../figure/BPU/FTB/port1.png)

上图展示了分支预测器中 FTB 模块针对 fallThrough 地址为 0x2000001062 的请求连续三拍在分支预测器不同阶段输出预测结果的接口。

### 更新接口

![更新接口](../figure/BPU/FTB/port2.png)

上图展示了 FTB 模块的一次针对 0x2000000E00 地址的更新操作，所有更新数据在一拍内全部传递。

## FTBBank

### 接口时序

#### 读数据接口

![读数据接口](../figure/BPU/FTB/port3.png)

上图展示了 FTBBank 读数据接口，FTBBank 在收到请求一拍后回复数据，即 16303ps 处回复的为 16301ps 的 0x2000001060 地址请求。

#### 更新读数据接口

![更新读数据接口](../figure/BPU/FTB/port4.png)
上图展示了 FTBBank 更新读数据接口，FTBBank 在收到更新读请求一拍后回复数据，回复的数据被外 部在一拍后用于更新写数据，可以注意到请求一拍后的 pftAddr 被用于结果读出一拍后的数据写入。

#### 更新写数据接口

![更新写数据接口](../figure/BPU/FTB/port5.png)
上图展示了 FTBBank 更新写数据接口，在收到写请求后一拍，数据完成写入。

### 功能概述

如上所述，FTBBank 主要存储 FTB 项，为 SRAM 模块的简单封装。
