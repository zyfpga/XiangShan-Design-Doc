# XiangShan CtrlBlock 设计文档

- 版本：V2R2
- 状态：OK
- 日期：2025/01/15
- commit：[xxx](https://github.com/OpenXiangShan/XiangShan/tree/xxx)

## 术语说明

Table: 术语说明

| 缩写 | 全称 | 描述 |
| --- | --- | --- |
| - | Decode Unit | 译码单元 |
| - | Fusion Decoder | 指令融合 |
| ROB | Reorder Buffer | 重排序缓存 |
| RAT | Register Alias Table | 重命名映射表 |
| - | Rename | 重命名 |
| LSQ | Load Store Queue | 访存指令队列 |
| SSIT | Store Set Identifier Table | 存储指令符号表 |
| - | Wait Table | 加载指令等待表 |
| - | Dispatch | 派遣 |
| IntDq | Int Dispatch Queue | 定点派遣队列 |
| fpDq | Float Point Dispatch Queue | 浮点派遣队列 |
| lsDq | Load Store Dispatch Queue | 访存派遣队列 |
| - | Redirect | 指令重定向 |
| pcMem | PC MEM | 指令地址缓存 |
| jalrTargetMem | Jalr Target Mem | 跳转目标地址缓存 |

## 子模块列表

Table: 子模块列表

| 子模块 | 描述 |
| --- | --- |

## 设计规格

- TODO

## 功能

CtrlBlock 模块包含指令译码（Decode）、寄存器重命名（Rename，RenameTable）、指令分派（Dispatch，DispatchQueue）、提交部件（ROB）、重定向处理和快照重命名恢复。

译码功能部件在每个时钟周期会从指令队列头部取出 6 条指令进行译码。译码过程是将指令码翻译为方便功能部件处理的内部码，标识出指令类型、所需要操作的寄存器号以及指令码中可能包含的立即数，用于接下来的寄存器重命名阶段。对于复杂指令，选出后通过 DecodeCompunit（一次一条）进行指令拆分，对于 vset 指令存储到 Vtype 中知道指令拆分。最后以复杂指令在前，简单指令在后每周期选出 6 个 uop 传递到重命名阶段。译码阶段还包括发出读 RenameTable 请求。

重命名阶段负责管理和维护寄存器与物理寄存器之间的映射，通过对逻辑寄存器的重命名，实现指令间依赖的消除，完成指令的乱序调度。重命名模块主要包含 Rename、RenameTable 两个模块，分别负责 Rename 流水级的控制、(体系结构/推测)重命名表的维护，Rename 中包括 FreeList 以及 CompressUnit 两个模块，负责空闲寄存器的维护以及 Rob 压缩。

派遣阶段包括两级流水级，第一级 Dispatch 负责将指令分类并发送至定点、浮点与访存三类派遣队列，第二级 DispatchQueue 负责将派遣队列中对应类型的指令进一步根据不同的运算操作类型派遣至不同的 Dispatch2IQ。

指令流在 CtrlBlock 的传递过程为：CtrlBlock 读取 Frontend 传入的 6 条指令对应 ctrlflow，经过 decode 增加译码逻辑寄存器、运算操作符等信息，复杂指令经过 DecodeComp 添加指令拆分信息，每周期选出六条 uop 输出，并发出读 RAT 请求。对于可以进行指令融合的 uop，在进入 rename 时进行融合以及清除。之后经过 rename 增加物理寄存器信息以及 rob 压缩信息后传入 dispatch，最后通过 dispatch 进到 rob / rab / vtype 申请 entry，根据指令类型输出到 dispatch queue。这些模块只有 dispatch queue 顺序进，乱序出，其他模块都是顺序进，顺序出。

（图）

### 译码

标量指令的译码过程同南湖。

对于向量指令，先使用和标量指令相同结构的译码表进行译码，译码的同时拿到指令拆分类型，接下来会根据指令拆分类型进行拆分，拆分的过程相当于重新修改源寄存器号、源寄存器类型、目标寄存器号、目标寄存器类型、更新 uop 数量，用于控制 rob 写回时一条指令需要写回的数量。直到拆分出的所有 uop 完成 rename 过程后，译码 ready 信号才能够置为 1。

由于除了 i2f 的标量浮点指令现在使用向量浮点模块运行，因此 fpdecoder 中的译码信号只使用其中用到的 4 种（typeTagOut、wflags、typ、rm），用法与南湖相同。使用向量浮点模块运行的浮点指令，需要在向量译码单元中获得使用的 futype 以及 fuoptype，并使用 1bit isFpToVecInst 信号区分，该浮点指令是浮点指令还是向量浮点指令，从而在共用向量运算单元时能进行区分。

#### 译码阶段输入

译码阶段除了接受来自前端的指令流，还需要接受来自 rob 的 Vtype 相关：walk，commit，vsetvl 信息，指导向量复杂指令译码。

#### 译码输出

与 MemCtrl：译码阶段还会发出 ssit waittable 读请求，与 memCtrl 进行交互，在下一拍输出给 rename。

与 fusionDecode：输出指令流以及控制指令融合是否开启。

与 rename：流水输出 6 个 uop；如果出现 redirect 阻塞直到 Ctrlblock 中 redirect 发往前端后，前端发出正确指令流。

与 RAT：译码发出读推测重命名请求。

### 寄存器重命名

Rename 模块接收来自 Decode 模块的指令译码信息，并根据译码信息为指令分配 robIdx 和物理寄存器，通过操作数查询对应的物理寄存器。同时，该模块还会根据指令译码信息、指令提交信息和来自 RenameTable 的寄存器释放信息维护 freeList 的状态，以及根据指令译码信息和指令提交信息向 RenameTable 发送写请求，以更新推测执行时的寄存器映射状态。此外，该模块还会处理来自 ROB 的重定向请求，根据重定向信息重新更新 freeList 的状态。在完成重命名后，Rename 将重命名后的指令信息发送至 Dispatch 模块。

RenameTableWrapper 共有 12 个整数寄存器读端口、18 个浮点寄存器读端口和 30 个向量浮点寄存器读端口，其中整数寄存器读端口 2 个为一组、浮点寄存器读端口 3 个为一组、向量寄存器读端口 5 个为一组，各自均有 6 组读端口。整数寄存器读端口用于读取整数逻辑寄存器到整数物理寄存器的推测映射关系，浮点寄存器读端口用于读取浮点逻辑寄存器到向量浮点物理寄存器的推测映射关系，向量寄存器读端口用于读取向量逻辑寄存器到向量浮点物理寄存器的推测映射关系。

RenameTable（RAT）被用作整数寄存器的重命名表，其中维护了逻辑整数寄存器与物理整数寄存器的映射关系。其有 12 个读推测重命名表端口、6 个写推测重命名表端口和 6 个写体系结构重命名表端口，内部则由 32 个宽度为 8 的寄存器来实际维护映射关系。

#### 重命名输入

除了来自译码阶段输入，还需要接受 RAT 的推测重名数据返回；指令融合信息，以及根据指令融合情况修改译码输入指令流；ssit，waittable信息；Ctrlblock snapshot 控制信息及出入队指针；rab 提交信息。

#### 重命名输出

与 rat：写重命名信息。

与 dispatch：流水输出 rename 后的 uop 信息：在 dispatch recv 有效时。

与 snapshot：enqdata，允许生成快照。

### 分派

Dispatch 模块对 Rename 后的 6 条指令进行进一步的解析和分类，将不同类型的指令送至不同的 Dispatch Queue 中。

Dispatch 对重命名后的指令按指令类型进行分派，每次分派 6 条指令。输入端为 Rename 模块，输出端为 toIntDq，toFpDq，toLsDq 三类分派队列，以及重排序队列（ROB）和 LSQ（只有 load / store 指令），其中向量指令和浮点指令公用 FpDq。

Dispatch Queue 有三种类型，整数队列 IntDq，浮点队列 FpDq，访存 LsDq，其中 IntDq  和FpDq 的 size 是 16，LsDq 的 size 是 18；IntDq 的出队宽度 DeqWidth 是 8，FpDq 和 LsDq 的出队宽度 DeqWidth 是 6。

该模块的处理分为四部分。

第一部分进行指令鉴别，判断从 Rename 传入的指令类型是否是整型指令、是否是分支指令、是否是浮点指令、是否是向量指令，是否是标量访存指令、是否是标量存储指令、是否是向量访存指令、是否是向量存储指令、是否是 AMO 指令、是否被阻塞、是否等待执行。

第二部分根据第一部分得到的类型信号更新 uop 的信息，包括 load 指令延迟信号、单步调试信息。其中针对 lui 指令，将 psrc(0) 的值设为 0。如果发生重定向，singleStep 状态拉低，如果开启了 singleStep，Rename 发来了第一条指令，且第一条指令可以进入 ROB，singleStep 状态置高。同时使用 checkpoint_id 寄存器计数来自 Rename 的指令个数。此外，当来自 Rename 的指令有效，同时 uop 的 storeSetHit 拉高，Dispatch 模块向 lfst 模块发送请求，并将指令是否是 store 指令信号，uop 的 ssid 信号，uop 的 robidx 信号传给 lfst。如果配置了 StoreSetEnable 参数，lfst 响应的 shouldWait 信号反馈给 uop 的 loadWaitBit 信号，lfst 响应的 robidx 信号反馈给 uop 的 waitForRobIdx 信号；如果没有配置 StoreSetEnable 参数，同时指令是访存指令，但不是 store 指令，来自 Rename 的 loadWaitBit 为高时，uop 的 loadWaitBit 置高。如果开启了 singleStep，会将 singleStep 置位。

第三部分，判断指令是否被派遣，只有当所有资源都是充足的（DQ 由足够空项、ROB 有足够空项等），需要的资源都已经 ready，没有被阻塞，指令才能派遣到下一级。

第四部分，进入 DQ 的指令更新 Rename 的 receive 信号，表示 uop 被派遣队列接收。此外，Dispatch 还会向 BusyTable 发出信号。如果分配了非零整数寄存器，则将 isInt 信号置高；如果分配了浮点寄存器或向量寄存器，则会将 isFp 置高。物理寄存器的地址也一并传给 BusyTable。

如果一条指令能够进入 ROB，那么就将对应指令与 Rename 握手的 ready 信号拉高。如果 Rename 没有发送一条有效指令给 Dispatch，ready 信号也拉高。

#### 输入

来自rename的流水输入。来自rob的resp。

Rob / dispatchqueue / lsq canaccept。

#### 输出

输出到 Rob / dispatchqueue / lsq canaccept 才能输出。

### 重排序缓存

在处理器核中，指令被顺序译码和重命名、乱序发射和执行，但是要有序提交（commit）。重定序队列负责指令的有序结束，它从寄存器重命名模块获取程序指令序信息，并有序地保存流水线中所有已经完成寄存器重命名但未提交的指令。指令在功能部件执行完毕并写回（writeback）后，重定序队列按照程序指令序顺序提交这些指令。

ROB 的本质是一个循环队列，从出队指针处提交，从入队指针处进入。

ROB 包括 6 个主要模块：

- Rab，负责维护commit或walk时各个rat的状态，和rename交互。
- RobEnqPtrWrapper，维护入队指针。
- NewRobDeqPtrWrapper，维护出队指针。
- ExceptionGen，异常产生模块。
- SnapshotGenerator，快照产生模块。
- VTypeBuffer，维护Vtype的类似Rab的结构，和decode交互。

Rob，Rab，VTypeBuffer 都是需要进行 walk 的模块，由 Rob 给其它两个模块发送 walk 相关的信息，其它两个模块内部自己 walk。

目前 RobSize 为 160。首先初始化一个 RobSize 大小的循环队列，出/入队指针（RobPtr）通过 value 和 flag 两个变量来模拟循环队列，由于队列的大小为 RobSize，因此当 value 的值在 RobSize - 1 的基础上增加 1 之后，会被置为 0，此时需要反转 flag 位来标记该过程，每当发生 value = RobSize - 1，value++ 或 value = 0，value-- 的时候，都会通过翻转 flag 来标记。当循环队列为空的时候，deqptr.value = enqptr.value，deqptr.flag = enqptr.flag，循环队列满的时候 deqptr.value = enqptr.value, deqptr.flag =/= enqptr.flag。

Rob 中有一个大小为 RobSize 的 RobEntries 用来存放 RobEntry 的数据，包含如下信号：其中 vxsat 表示向量定点溢出标志位，realDestSize 表示这个 entry 包含的指令写目的寄存器的个数，uopNum 表示这个 entry 包含的 uop 个数，debug_* 是一些 debug 信号。

ROB 采用分 8 个 Bank 读的设计，根据 robidx 的最低 3 bit 分 bank 每次读取 RobEntry 数据的时候，使用一个独热的 Line 指针（20 bit），从 8 个 Bank 中读出当前 Line 和下一 Line 的数据（共 16 个），结合当拍的写回信息更新后，写到 8 个 robDeqGroup 寄存器中，指令提交时从 8 个 robDeqGroup 中读数据进行提交。

hasCommitted 表示当前行每一条指令是否已经提交，作为其它指令是否可以提交的条件之一，allCommitted 表示当前行全部提交，是切换行指针的控制信号，allCommitted 为 1 时，读出的 16 个数据的第二行，也就是后 8 个数据更新后写入到 robDeqGroup。

目前 Ctrlblock 新增加了 Gpamem 模块类似于 Pcmem，存储前端的 ftq 与对应的 gpaddr（startAddr & nextLineAddr）信息。Rob 在 exception 输出的前一拍发出 gpaddr 读请求以读地址的 ftq 信息，第二拍得到返回的 gpaddr 信息。最终通过 robio 与 csr 直接交互。

### Redirect

在 ctrlblock 中主要负责 redirect 的生成以及发往各个模块。

#### redirect 的生成

Ctrlblock 中生成的 Redirect 主要包括两部分：通过 redirectgen 汇总的处理器执行时发生的错误（分支预测，访存违例）（后面称这部分重定向为 exuredirect）；以及来自 rob exceptiongen 生成的 robflush：中断（csr）/异常/刷流水（csr+fence+load+store+varith+vload+vstore）+前端异常。Rob 中发来的异常/中断/刷流水重定向处理类似。

对于redirectgen汇总的重定向：

- 功能单元写回的 redirect（jump, brh）在打一拍且没有被更老的已经处理过 redirect 取消的情况下输入到 redirectgen 模块。
- Memblock 写回的 violation（访存违例）在打一拍且没有被更老的已经处理过的 redirect 取消的情况下输入到 redirectgen。
- Redirectgen 选择最老的 redirect 在输入后等待一拍接受 pcMem 传回的重取指数据再输出。
- 对于 robflush 信号，在 s0 接收到后，需要等待一拍到 s1 以接收 pcmem 传回的重新取指数据。

Ctrlblock 生成 Redirect 时会优先重定向 robflush 信号，当不存在 robflush 时才会处理 exuredirect。Redirect 信号主要包括：valid 控制是否需要取消；robidx；发送给前端的 CFIupdate：发生异常的 pc 值，正确的目的地址 pc，预译码信息；发送给前端的发生异常的 ftqidx 值；用于访存违例更新访存违例预测 mdp 的 stftqidx。

上述部分整体框图如下：

(图)

#### redirect 分发

Ctrlblock在生成出Redirect信号后，向流水级各个模块分发重定向信号。

对于decode发送当前redirect或redirectpending（即decode等待直到Ctrlblock发给前端的redirect准备完成，使得前端有正确指令流到达之后才可继续流水）；

对于rename，rat，rob，dispatch，mem发送当前redirect；

对于dispatchqueue，issueblock，datapath，exublock发送打一拍后的redirect（时序）。

其中比较特殊的是发送给前端的redirect以及redirect对于访存违例预测mdp的更新。

##### 发送给前端的重定向以及造成的影响

总共包括三部分：rob_commit, redirect，ftqIdx(readAhead，seloh)。

对于robcommit：由于传递给前端的robflush需要等待六拍，需要避免携带robflush的指令提前提交导致的，提交在flush之前的错误，因此在ctrlblock直接刷掉带有robflush的commit。对于exuredirect，携带exuredirect指令需要写回rob后等待walk完毕才可以提交（至少walk两拍以上），因此commit一定在exuredirect之后写回前端。

对于redirect：发送给前端的redirect信号包括额外的CFIupdate,ftq信息通过额外的readAhead以及seloh更新。

首先exuredirect(jmp.brh,loadreplay)部分，这部分的CFIupdate以及ftqidx信息在功能单元传递过来的时候已经包括在里面，因此无需进行特殊处理。

其次rob发出的flush中， exception对CFI更新的目的地址需要等待从csr中得到：

T0：rob发出flush（异常/中断/刷流水）；T1：rob发出exception（异常/中断）；T2：exception在exuunit5被打两拍; T3：csr接收到exception，生成traptarget；T4：csr 发出traptarget，ctrlblock接收到target；T5：ctrlblock发往前端的cfiupdate.target。因此对于robflush生成的发送给前端的redirect信号统一在T6时发送。

剩下的冲刷流水导致的目的地址更新，在ctrlblock中根据是否刷新自身来选择生成目的地址更新，pc值通过之前与pcmem交互得到。其中比较特殊的是csr发出的冲刷流水中XRet，这种情况下目的地址更新也需要从csr中得到，不过csr生成Xret的通路不需要依赖rob发回的exception，可以直接与Ctrlblock通过csrio交互。

对于ftqIdx：Ctrlblock主要发送两组数据ReadAhead以及SelOH。

其中ReadAhead用于前端提前一拍读取到重定向相关的ftqidx。ReadAhead中前四个是exuredirect(jmp,brh,load)，第五个是robflush。

SelOH，用于选择有效的ftqidx：前四个通过redirectgen输出的独热码选择，第五个通过T6发送到前端的redirect是否有效选择。

上述部分整体框图如下：

(图)

##### 对于访存违例预测 mdp 的更新

Ctrlblock对mdp的更新，首先在redirectgen模块在s1得到访存违例指令的重新取指数据，s2得到store_pc的重取指数据。之后通过memctrl模块对mdp的ssit和waittable更新。

#### 保证 redirect 发出顺序（新到旧，或最旧）

##### 新的exuredirect在旧的robflush之后发出

Exuredirect写回时，往前看三拍是否有更老的redirect。

假设在S0时刻，一条最老的robflush到来，在s2时刻redirect发送到exublock。此时s3之后的较新的exuredirect在exublock被刷新，即不会出现s3之后较新的exuredirect写回。

对于s0-s2返回的较新的exuredirect：s0到来的exuredirect在redirectGen被上一条robflush刷新，s1，s2返回的exuredirect，在数据写回时向前看三排是否有更老的redirect从而被s1,s2,s3 rob_flush刷新。

##### 新的exuredirect在旧的exuredirect之后

Exuredirect写回时，往前看两拍是否有更老的redirect。

假设在s0时刻一条最老的exuredirect写回，在s3时刻发回exublock。此时s4之后不会有较新的exuredirect写回。

对于s0写回的exuredirect，会在redirectGen模块中保证最老。

对于s1写回的exuredirect，会在redirectGen中被上一条取消。

对于s2，s3写回的exuredirect，会在写回时被s2，s3redirect取消。

##### 新的robflush在旧的redirect之后

这种情况，rob保证了不会出现，robflush输出结果是当前robdeq的指令带有异常/中断标志，而robdeq即当前最老的robidx，一定比现有的redirect更老。

##### 新的robflush在旧的robflush之后

这一部分主要在rob中保证，exceptionGen获得最老robflush，同时robflush发出时检查上一条flushout。S2之后的robflush均被取消。

### 快照恢复

对于重命名恢复，目前昆明湖采用了快照恢复阶段：在重定向时不一定恢复到arch状态，而是可能会恢复到某一个快照状态。快照即根据一定规则，在重命名阶段保存的spec state，包括ROB enqptr；Vtypebuffer enqptr；RAT spec table；freelist Headptr（出队指针）以及ctrlblock用于总体控制 robidx。目前上述模块均各自维护四份快照。

#### 快照的创建

对于快照创建时机，目前在rename中进行管理。由于注意到对性能造成主要影响的重定向来源仍然是分支错误造成的重定向，因此选择在分支跳转指令处创建快照；同时为了在没有分支跳转的情况下其他的重定向也能用到快照恢复，因此固定每隔commitwidth\*4=32条uop打一份快照。

Rename模块会对输出的六条uop都打上snapshot标志，表示uop是否需要打上快照，在Ctrlblock中会把六条uop上的snapshot标志汇总到第一条uop。该操作为了解决快照机制在blockBackward下的正确性：即如果在六条uop中出现blockbackward，且在blockbackward之后需要打上snapshot，该snapshot会由于blockbackward而无法在rob中打上快照，将所有snapshot放到第一条就可以解决这个问题。

Rat，freelist，以及ctrlblock的快照创建均通过rename模块输出的snapshot标志控制。存储数据由各个模块自己管理。

Rob，vtype的快照创建除了rename输出流到rob的snapshot标志还需要考虑非blockbackward以及rab，rob，vtypebuffer没有满。这里我们可以看到rob，vtype的快照创建和前述模块的快照写入并不在一个周期，但通过snapshot标志随着rename输出流到rob我们可以保证写入的robidx相同即可同步。

#### 快照的删除

快照删除主要包括两种情况，一种在commit的时候删除掉过期的快照；另一种是redirect的时候删除掉错误路径上的快照。

对于commit的时候删除快照：Ctrlblock通过控制deq信号删除快照：robcommit的八条uop有一条与当前deqptr指向的快照中第一条uop一致则删除过期快照。Ctrlblock将deq信号传递到上述各个模块中同步删除commit过期快照。

对于redirect的时候：Ctrlblock通过提供flushvec信号删除错误路径上的快照：判断快照的第一条uop是否比当前redirect要新（这里要注意套圈的情况），如果老则把这条快照刷掉，即flushvec相应位置1。Ctrlblock将flushvec传递到上述模块同步刷新错误路径上的快照。

#### 快照的管理

Ctrlblock通过自身维护一个存储robidx的快照副本，在重定向到来时可以方便的向各个模块告知是否命中快照以及命中快照的编号。Ctrlblock遍历快照，在存在比当前redirect更老（或者不刷自己的情况下相等），允许使用快照恢复，并记录命中快照的编号，传递到上述模块中。

通过快照恢复spec state由各个模块自身控制。

上述部分整体框图：

(图)

## 总体设计

### 整体框图

（图）

### 接口列表

见接口文档

## 模块设计

### 二级模块 RedirectGenerator

#### 功能

RedirectGenerator 模块负责汇总处理器执行时发生的错误，包括分支预测错误，访存违例，并进行比较得到最老的错误，以生成Redirect数据，控制各个模块是否需要取消等。

该模块主要包括三级流水：

S0：接受输入的三个exuredirect即分支预测错误，加上一个 loadReplay 访存违例。判断得到最老的错误，同时也判断这些指令不会被之前的redirect刷掉（stage2redirect），或者被rob的异常刷掉。

同时发出最老redirect指令的重新取指信号，等待PcMem返回。

S1：PcMem返回，根据当前最老redirect类型生成target，将pc，target，Predecode信息写入到redirect cfiUpdata中，输出stage2redirect并检查是否被rob异常刷掉。

同时如果最老redirect是访存违例，发出对store_pc的重新取指信号，等待PcMem返回

S2：store_pc取指返回，如果最老redirect是访存违例，根据返回数据更新wait table ssit，输出memPredUpdate 更新。

#### 整体框图

（图）

#### 接口列表

见接口文档

### 二级模块SnapshotGenerator

#### 功能

SnapshotGenerator模块主要用于生成快照，存储维护。其本质是一个循环队列，每个snapshotGenerator循环队列维护最多四份快照。

入队：在循环队列不满，且入队信号未被redirect取消的情况下，下一拍在enqptr入队，更新enqptr。

出队：在出队信号未被redirect取消的情况下，下一拍在deqptr出队，更新deqptr。

Flush：根据刷新向量在下一拍刷新掉对应的快照。

更新enqptr：如果有空的快照，选择离deqptr最近的作为新的enq指针

Snapshots: snapshots队列寄存器直出

#### 整体框图

（图）

#### 接口列表

见接口文档

### 二级模块 MemCtrl

MemCtrl模块主要用于与mdp访存违例预测相关模块交互，包括StoreSet中的LSFT,SSIT 以及waittable模块。

SSIT/waittable：

Update:将RedirectGenerator s2阶段输出的由于访存违例需要对预测进行更新的：memPredUpdate信号打一拍后送入update。

冲刷控制：将csr中的lvpred\_timeout等打一拍输入.

读请求：来自译码阶段用来读ssit和waittable请求，读请求同步，当拍输入，下一拍得到，传入rename阶段。

LSFT：

与dispatch进行交互：通过req进行输入，resp输出。Dispatch req打一拍输入，resp当拍输出。

Redirect刷新：传入打一拍后的redirect信号

Storeissue：通过storeissue接口通知lfst指令被issued，打一拍后传入

#### 整体框图

（图）

#### 接口列表

见接口文档
