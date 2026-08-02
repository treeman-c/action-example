# komari-argo

基于官方 `ghcr.io/komari-monitor/komari` 镜像叠加 Cloudflare Argo Tunnel + GitHub
数据持久化的一体化探针面板镜像，参数体系参照 `daxia2023/nezv1` 一类镜像的常见约定。

> 重要：本仓库里的 GitHub Action **只负责构建并推送镜像**（CI/CD），
> 不在 Actions 里运行服务本身。所有敏感参数（ARGO_AUTH / GH_PAT / DASH_TOKEN 等）
> 都属于**运行时**环境变量，应该在你实际部署镜像的机器/平台上通过
> `docker run -e ...` 或平台的"环境变量/Secret"功能注入，
> 不要写进 Dockerfile、workflow 文件或提交到仓库里。

## 目录结构

```
.
├── .github/workflows/build-image.yml   # 构建并推送镜像的 Action
├── docker/
│   ├── Dockerfile
│   ├── entrypoint.sh
│   ├── backup.sh
│   └── restore.sh
└── README.md
```

## 构建镜像需要的 GitHub Secrets（仓库级，与运行参数无关）

在你 fork/新建的 GitHub 仓库 `Settings -> Secrets and variables -> Actions` 添加：

| Secret | 说明 |
|---|---|
| `DOCKERHUB_USERNAME` | Docker Hub 用户名 |
| `DOCKERHUB_TOKEN` | Docker Hub Access Token（不是密码） |

配置好后 push 到 `main` 分支或手动触发 workflow，即可在
`docker.io/<你的用户名>/komari-argo:latest` 得到镜像。

## 运行参数（对应 daxia2023/nezv1 的参数体系）

| 变量 | 必填 | 说明 |
|---|---|---|
| `API_TOKEN` | 否 | 写入 `/app/data/.api_token`，用于对接 Agent 时核对/回填面板里的接入 Token |
| `ARGO_AUTH` | 否 | Argo 隧道凭证。支持 **Token 字符串**（Cloudflare Zero Trust 远程管理隧道）或**隧道凭证 JSON**（`cloudflared tunnel create` 生成的 credentials 内容），二选一，留空则不启用隧道，仅本地监听 |
| `ARGO_DOMAIN` | 否（配 ARGO_AUTH 时建议填） | 对外访问域名，例如 `nz.treeman.xx.kg` |
| `CF_IP` | 否 | GitHub 下载加速反代域名，例如 `cdn.814046.xyz`，用于加速拉取 cloudflared 等文件 |
| `DASH_TOKEN` | 否 | 映射为面板管理员密码 `ADMIN_PASSWORD` |
| `GH_CLIENTID` / `GH_CLIENTSECRET` | 否 | GitHub OAuth App 凭证，透传为 `OAUTH_CLIENT_ID` / `OAUTH_CLIENT_SECRET`（取决于所用 komari 版本是否已支持三方登录） |
| `GH_EMAIL` | 否 | 提交备份 commit 用的 git 邮箱 |
| `GH_PAT` | 否（要用备份功能则必填） | 具备目标仓库读写权限的 GitHub Personal Access Token |
| `GH_REPO` | 否（要用备份功能则必填） | 备份数据存放的仓库，格式 `用户名/仓库名`，**强烈建议设为 private** |
| `GH_USER` | 否 | GitHub 用户名，同时作为面板默认管理员账号 `ADMIN_USERNAME` |
| `NO_AUTO_RENEW` | 否 | 设为 `1` 关闭自动定时备份 |
| `SUB_NAME` | 否 | 实例展示名 / 备份分支名，默认 `main` |
| `UUID` | 否 | 实例唯一标识，不填则自动生成 |

## 运行示例

```bash
docker run -d \
  --name komari-argo \
  -p 25774:25774 \
  -e API_TOKEN='xxxx' \
  -e ARGO_AUTH='eyJhIjoi...你的Token或JSON凭证' \
  -e ARGO_DOMAIN='nz.treeman.xx.kg' \
  -e CF_IP='cdn.814046.xyz' \
  -e DASH_TOKEN='your-dashboard-password' \
  -e GH_CLIENTID='xxxx' \
  -e GH_CLIENTSECRET='xxxx' \
  -e GH_EMAIL='[email protected]' \
  -e GH_PAT='ghp_xxxx' \
  -e GH_REPO='yourname/komari-backup' \
  -e GH_USER='yourname' \
  -e NO_AUTO_RENEW='' \
  -e SUB_NAME='my-node' \
  -e UUID='xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' \
  -v $(pwd)/data:/app/data \
  你的用户名/komari-argo:latest
```

首次启动后查看日志获取初始管理员账号密码（若未通过 `DASH_TOKEN`/`GH_USER` 指定）：

```bash
docker logs komari-argo
```

## 关于 ARGO_AUTH 的两种取值

1. **Token 模式**（推荐，最简单）：在 Cloudflare Zero Trust 后台创建
   "Remotely-managed" 隧道，把生成的一长串 Token 填入 `ARGO_AUTH`，
   并在 Cloudflare 后台的 Public Hostname 里把 `ARGO_DOMAIN` 指向本容器的
   `http://localhost:25774`。
2. **JSON 凭证模式**：用 `cloudflared tunnel login` + `cloudflared tunnel create`
   在本地生成的 credentials JSON 内容整体填入 `ARGO_AUTH`，容器会自动生成
   `config.yml` 并把 `ARGO_DOMAIN` 路由到本地端口。

## 安全提示

- `GH_PAT` 建议使用 Fine-grained token，只授予目标备份仓库的读写权限。
- `GH_REPO` 用于存放面板数据库，**务必设为私有仓库**，其中可能包含服务器信息、
  管理员凭证等敏感数据。
- 不要把 `ARGO_AUTH` / `GH_PAT` / `DASH_TOKEN` 写进 Dockerfile 或提交到 git 历史中。
