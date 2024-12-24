# XiangShan ICache 设计文档

## WayLookup 子模块文档

WayLookup 为 FIFO 结构，暂存 IPrefetchPipe 查询 MetaArray 和 ITLB 得到的元数据，以备 MainPipe 使用。同时监听 MSHR 写入 SRAM 的 cacheline，对命中信息进行更新。更新逻辑与 IPrefetchPipe 中相同，见 [IPrefetchPipe 子模块文档中的“命中信息的更新”](IPrefetchPipe.md#命中信息的更新)一节。

![WayLookup 结构](../figure/ICache/WayLookup/waylookup_structure.png)

允许 bypass（即，当 WayLookup 为空时，直接将入队请求出队），为了不将更新逻辑的延迟引入到 DataArray 的访问路径上，在 MSHR 有新的写入时禁止出队，MainPipe 的 S0 流水级也需要访问 DataArray，当 MSHR 有新的写入时无法向下走，所以该措施并不会带来额外影响。
