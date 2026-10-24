# Cloud-Development

基于Docker环境构建的一个隔离开发虚拟环境

## 本项目的缘由

我需要一个可以快速拉起、撤销环境修改的容器，且具备隔离的Agent开发，以便我可以直接开完全访问模式

## 镜像变体

| Tag | 说明 |
|---|---|
| `vxxxxxxxx`（无后缀） | slim 版（NoDesktop-Base）：不含远程桌面，体积更小，`FROM :base` |
| `vxxxxxxxx-desktop` | 完整版（Desktop-Base，默认）：XFCE4/xrdp 远程桌面（端口 3390），`FROM :desktop` |

> 关于开发思路：
> 
> 由于Agent是更新比较频繁的，但是开发依赖却是更新频率较低的。
> 
> 所以本项目拆分成两层docker，一层为base，用于存放更新频率低的开发依赖、基础环境，一层为动态层，用于存放更新较为频繁的agent等用途
> 
> 如果你需要定制一个适用你的，可以直接从base入手，将开发依赖进行适配即可，动态层已经覆盖安装了主流的开发Agent（例如CC、OpenCode）