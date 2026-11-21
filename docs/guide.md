# llama-server-setup-tui 使用指南

這份指南補充 README 沒寫的細節：每個參數的作用、使用紀錄怎麼存、碰到特殊情況時會發生什麼事。

## 名詞

| 名詞 | 白話解釋 |
|---|---|
| GGUF | llama.cpp 用的 model 檔案格式，副檔名 `.gguf` |
| mmproj | 把圖片轉成 model 看得懂的 token 的投影檔；沒有它，model 只能讀文字 |
| prefill | 開始生成回答之前，先把整個 prompt（包含圖片 token）算過一遍 |
| prompt cache | 把上一次 prefill 的結果（KV）存起來，下一個請求開頭一樣時直接拿來用 |
| slot | server 處理請求的位子，一個 slot 一次只處理一個請求 |
| context checkpoint | 為了沿用 cache 而另外存下的中間狀態，SWA 架構的 model 會用到 |
| 分片 model | 太大的 model 被切成 `-00001-of-0000N.gguf` 好幾個檔案 |

## 設定

### 選檔畫面從哪裡開始

script 第 8 行：

```bash
MODELS_ROOT="$HOME"
```

預設是家目錄，用 `..` 可以一路走到 `/`。如果你的 model 都放在同一個地方，可以改成那個路徑，少按幾次鍵。

### 怎麼找到 llama 和 whiptail

script 一開始用 `type -P llama` 在 `PATH` 上找 `llama` 執行檔，同名的 alias 或 shell function 不算。找不到時會印出：

```text
llama CLI not found in PATH. Install llama.cpp so that 'llama serve' works.
```

`whiptail` 也會先檢查，缺少時印出 `whiptail not found. Install it, e.g. 'sudo apt install whiptail'.`。兩種情況都以 exit code 1 結束。

## 每天怎麼用

### 選單的流程

從執行 script 到啟動 server，會經過下面這幾步：

```text
執行 script
  ▼
有最近紀錄嗎？ ──沒有──► 跳到「選檔」
  ▼ 有
Recent models ──選 1~5──► 跳到「寫入紀錄」
  ▼ 選 B
選檔：Select model ─► Select mmproj
  ▼
寫入紀錄 ─► 啟動 llama serve
```

任何一個畫面按 Esc 或 Cancel，都會印出 `Cancelled.` 並以 exit code 1 結束，紀錄檔不會改變。
選檔畫面只列資料夾和 `.gguf`，`.gguf` 會顯示檔案大小。mmproj 畫面的第一項是 `(no mmproj)`。

### 改預設參數

接在 script 後面的參數會原封不動加在 `llama serve` 的最後面。同一個參數出現兩次時，llama.cpp 以後面那個為準，所以可以拿來覆蓋預設值：

```bash
./llama-server-setup-tui.sh --port 8899 --ctx-size 16384
```

## 參考

### 啟動參數

| 參數 | 值 | 為什麼 |
|---|---|---|
| `--model` | 選到的 model | |
| `--mmproj` / `--no-mmproj` | 選到的 mmproj | 選 `(no mmproj)` 時改帶 `--no-mmproj` |
| `--host` | `127.0.0.1` | 只讓本機連 |
| `--port` | `8888` | 預設 port |
| `--ctx-size` | `32768` | 不設的話用 model 自帶的長度，KV 會佔掉很多 VRAM |
| `--n-gpu-layers` | `all` | 整個 model 放進 GPU |
| `--parallel` | `1` | 只開 1 個 slot，記憶體用量固定，請求排隊處理 |
| `--no-cache-prompt` | | 不沿用上一個請求的 KV，每次從頭 prefill |
| `--cache-ram` | `0` | 關掉存在 RAM 的 prompt cache（llama.cpp 預設最多 8192 MiB） |
| `--ctx-checkpoints` | `0` | 不存 context checkpoint（llama.cpp 預設每個 slot 最多 32 份） |

環境變數：

| 變數 | 值 | 為什麼 |
|---|---|---|
| `MALLOC_MMAP_THRESHOLD_` | `131072` | 讓 glibc 用 mmap 配置 128 KiB 以上的記憶體，free 時直接還給系統，不會留在各個 thread 的 arena 裡 |

### 最近使用紀錄

- 位置：script 所在資料夾的 `.cache/llama-server-history.tsv`。路徑用 `readlink -f` 算，從 symlink 執行也會存在同一個地方。`.cache/` 已列在 `.gitignore`。
- 格式：一行一組 `model 路徑<TAB>mmproj 路徑`，最新的在最上面；選 `(no mmproj)` 時 mmproj 欄位是空的。
- 寫入時機：選好之後、啟動 `llama serve` 之前，所以 server 啟動失敗也會留下紀錄。
- 更新規則：這一組移到最前面，重複的合併，最多保留 5 組（`HISTORY_SIZE`）。
- 想清空：刪掉 `.cache/llama-server-history.tsv`。

### 記憶體實測

測試環境：llama.cpp b10217、NVIDIA RTX PRO 6000 Blackwell Workstation Edition（97887 MiB）、同一張 2000×3000 的 JPEG 連續送請求。數字是 server process 的 Anonymous 記憶體（`/proc/<pid>/smaps_rollup`）。

| model | `MALLOC_MMAP_THRESHOLD_` | 停止增加前的請求數 | 穩定後 |
|---|---|---|---|
| Gemma 4 26B A4B q4_0 | 沒設 | 約 45 | 約 1.38 GB |
| Gemma 4 26B A4B q4_0 | `131072` | 約 30 | 約 1.0 GB |
| Qwen3-VL 8B Q4_K_M | `131072` | 40 次內 | 約 0.47 GB（第 1 次到第 40 次只多 5.5 MB） |

每個請求的 `cache_n` 都是 `0`。純文字請求幾乎不會讓記憶體增加；圖片請求在穩定之前，增加量和像素數成正比（2000×3000 每次約 +15 MB，2400×800 每次約 +4.8 MB）。
同一張圖在 Gemma 4 是 285 個 token、每次約 0.4 秒；在 Qwen3-VL 是 4073 個 token、每次約 2.0 秒。

### 幾種特殊情況

- 選到分片 model 的其他片：llama.cpp 會馬上結束，錯誤訊息是 `illegal split file idx: 1 ... model must be loaded with the first split`。
- `.` 開頭的資料夾和檔案不會列出來，例如 `~/.cache`、`~/.unsloth`。放在這些地方的 model 選不到。
- script 不會檢查 mmproj 和 model 是否配對。
- 紀錄裡的檔案已經不存在時（例如硬碟沒掛載），那一組不會顯示，但會留在紀錄檔裡繼續佔名額。
