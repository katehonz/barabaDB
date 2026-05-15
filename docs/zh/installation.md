# BaraDB - 安装指南

## 系统要求

- **Nim 编译器** >= 2.2.0
- **OpenSSL 开发头文件** (用于 TLS 支持)
- **操作系统**: Linux、macOS、Windows

### 支持的平台

| 操作系统 | 架构 | 状态 |
|----------|------|------|
| Linux | x86_64 | ✅ 完全支持 |
| Linux | ARM64 | ✅ 完全支持 |
| macOS | x86_64 | ✅ 完全支持 |
| macOS | ARM64 (Apple Silicon) | ✅ 完全支持 |
| Windows | x86_64 | ✅ 支持 |
| FreeBSD | x86_64 | 🟡 社区测试 |

## 安装 Nim

### Linux

```bash
# 官方安装脚本
curl https://nim-lang.org/choosenim/init.sh -sSf | sh

# Ubuntu/Debian
sudo apt-get update
sudo apt-get install nim

# Fedora
sudo dnf install nim

# Arch Linux
sudo pacman -S nim
```

### macOS

```bash
# Homebrew
brew install nim

# MacPorts
sudo port install nim
```

### Windows

```powershell
# 使用 choosenim
curl.exe -A "MSYS2_$(uname -m)" -L https://nim-lang.org/choosenim/init.ps1 | powershell -

# 使用 winget
winget install nim

# 使用 scoop
scoop install nim
```

### 验证安装

```bash
nim --version
# 预期输出: Nim Compiler Version 2.2.0 或更高
```

## 安装 OpenSSL

### Linux

```bash
# Ubuntu/Debian
sudo apt-get install libssl-dev

# Fedora
sudo dnf install openssl-devel

# Arch Linux
sudo pacman -S openssl
```

### macOS

OpenSSL 已随系统提供。如有需要:

```bash
brew install openssl
```

### Windows

OpenSSL 已捆绑在 Nim Windows 分发版中。如需手动构建，
请从 [slproweb.com](https://slproweb.com/products/Win32OpenSSL.html) 下载。

## 构建 BaraDB

### 克隆仓库

```bash
git clone https://codeberg.org/baraba/bara-lang
cd barabaDB
```

### 安装依赖

```bash
nimble install -d -y
```

### 构建选项

#### 调试构建

```bash
nim c -d:ssl -o:build/baradadb src/baradadb.nim
```

#### 发布构建 (推荐)

```bash
nim c -d:ssl -d:release --opt:speed -o:build/baradadb src/baradadb.nim
```

#### 使用 Nimble Tasks

```bash
# 调试构建
nimble build_debug

# 发布构建
nimble build_release
```

#### 精简二进制文件

```bash
nim c -d:ssl -d:release --opt:size -o:build/baradadb src/baradadb.nim
strip build/baradadb
```

### 验证构建

```bash
./build/baradadb --version
# 预期输出: BaraDB v1.1.0 — Multimodal Database Engine
```

## 运行测试

### 所有测试

```bash
nim c -d:ssl -r tests/test_all.nim
```

### 特定测试套件

```bash
# 存储测试
nim c -d:ssl -r tests/test_storage.nim

# 查询引擎测试
nim c -d:ssl -r tests/test_query.nim

# 协议测试
nim c -d:ssl -r tests/test_protocol.nim
```

### 基准测试

```bash
nim c -d:ssl -d:release -r benchmarks/bench_all.nim
```

## 安装选项

### 系统级安装

```bash
# 构建发布版二进制文件
nimble build_release

# 安装到 /usr/local/bin
sudo cp build/baradadb /usr/local/bin/
sudo chmod +x /usr/local/bin/baradadb

# 创建数据目录
sudo mkdir -p /var/lib/baradb
sudo chmod 755 /var/lib/baradb
```

### 预编译二进制文件

为您的平台下载最新的发布版本:

```bash
# Linux x86_64
wget https://github.com/katehonz/barabaDB/releases/latest/download/baradadb-linux-amd64
chmod +x baradadb-linux-amd64
mv baradadb-linux-amd64 /usr/local/bin/baradadb

# Linux ARM64
wget https://github.com/katehonz/barabaDB/releases/latest/download/baradadb-linux-arm64
chmod +x baradadb-linux-arm64
mv baradadb-linux-arm64 /usr/local/bin/baradadb

# macOS
wget https://github.com/katehonz/barabaDB/releases/latest/download/baradadb-darwin-amd64
chmod +x baradadb-darwin-amd64
mv baradadb-darwin-amd64 /usr/local/bin/baradadb
```

### Docker

```bash
# 拉取官方镜像
docker pull barabadb/barabadb:latest

# 运行
docker run -d \
  -p 9472:9472 \
  -p 9470:9470 \
  -p 9471:9471 \
  -v baradb_data:/data \
  barabadb/barabadb
```

### Docker Compose

```bash
docker-compose up -d
```

### 嵌入式使用 (Nim 项目)

添加到您的 `.nimble` 文件:

```nim
requires "barabadb >= 0.1.0"
```

在代码中使用:

```nim
import barabadb/storage/lsm

var db = newLSMTree("./data")
db.put("key", cast[seq[byte]]("value"))
let (found, val) = db.get("key")
db.close()
```

## 首次运行

```bash
# 启动服务器
./build/baradadb

# 预期输出:
# BaraDB v1.1.0 — Multimodal Database Engine
# BaraDB TCP listening on 127.0.0.1:9472

# 使用 HTTP API 测试
curl http://localhost:9470/health

# 交互式 shell
./build/baradadb --shell
```

## 安装故障排除

### "cannot open file: hunos"

```bash
nimble install -d -y
```

### "BaraDB requires SSL support"

始终使用 `-d:ssl` 编译:

```bash
nim c -d:ssl -o:build/baradadb src/baradadb.nim
```

### 编译缓慢

使用并行编译:

```bash
nim c -d:ssl -d:release --parallelBuild:4 -o:build/baradadb src/baradadb.nim
```

### 二进制文件过大

使用大小优化:

```bash
nim c -d:ssl -d:release --opt:size --passL:-s -o:build/baradadb src/baradadb.nim
```

## 下一步

- [快速入门指南](quickstart.md)
- [配置参考](configuration.md)
- [架构概述](architecture.md)
- [BaraQL 查询语言](baraql.md)