# llama-server-setup-tui

在終端機用選單挑好 GGUF model 和 mmproj，馬上啟動一台關掉 prompt cache 的 llama.cpp server。

它像餐廳的點餐機：你點好主餐（model）和配菜（mmproj），它把單送進廚房（`llama serve`），而且每張單都從頭做，不沿用上一張單的半成品（cache）。

```text
你 ──挑 model + mmproj──► TUI ──帶好參數啟動──► llama serve :8888 ◄──送請求── 你的 app
```

取捨：每個請求都重新 prefill（把整個 prompt 從頭算一遍），換來記憶體用量會停在固定的範圍，不會跟著請求數一直增加。

## 需要什麼

- Linux 和 bash
- llama.cpp 的 `llama` 指令在 `PATH` 上，而且有 `serve` 子命令（在 b10217 測過）
- `whiptail`（Debian / Ubuntu：`sudo apt install whiptail`）
- 放得下整個 model 的 GPU：script 帶 `--n-gpu-layers all`

## 五分鐘上手

不用改任何設定，直接執行：

```bash
cd llama-server-setup-tui
./llama-server-setup-tui.sh
```

選檔畫面從家目錄開始，用 `..` 可以走到任何地方。用過一次之後，下次會先看到最近用過的組合：

```text
+------------------- Recent models -------------------+
| Pick a recent model + mmproj, or browse files.      |
|  1 gemma-4-26B_q4_0-it.gguf  +  gemma-4-26B-it-...  |
|  2 Qwen3VL-8B-Instruct-Q4_K_M.gguf  +  (no mmproj)  |
|  B Browse files...                                  |
+-----------------------------------------------------+
```

直接按 Enter 就是上一次的組合；選 `B` 進選檔畫面。
↑↓ 移動，Enter 確定，Esc 取消。選完 model 會接著選 mmproj，從 model 所在的資料夾開始。

## 試一下

server 起來後，另開一個終端機送一張圖（把 `page.jpg` 換成你的圖）：

```bash
IMG=page.jpg
printf '{"messages":[{"role":"user","content":[{"type":"text","text":"Describe this image in one sentence."},{"type":"image_url","image_url":{"url":"data:image/jpeg;base64,%s"}}]}]}' "$(base64 -w0 "$IMG")" \
  | curl -s http://127.0.0.1:8888/v1/chat/completions -H 'Content-Type: application/json' -d @-
```

你會拿到 OpenAI 格式的 JSON：`choices[0].message.content` 是回答，`timings.cache_n` 是 `0`，代表這次沒有沿用任何 cache。

## mmproj 該怎麼選

mmproj 是讓 model 看得懂圖片的投影檔，沒有它，model 只能讀文字。

| 你的 model | mmproj 選什麼 | 結果 |
|---|---|---|
| 看圖的 model（例如 Gemma 4、Qwen3-VL） | 同資料夾的 mmproj `.gguf` | 可以送圖片 |
| 純文字 model（例如 Sakura、HY-MT） | `(no mmproj)` | 只能送文字；送圖片會回 500 `image input is not supported` |

## 接到你的 app

把 app 的 OpenAI 相容 base URL 設成：

```text
http://127.0.0.1:8888/v1
```

三件事一定要記得：

- port 固定 8888。要同時開第二台，加 `--port`，例如 `./llama-server-setup-tui.sh --port 8899`。
- 只有 1 個 slot（`--parallel 1`），同時送進來的請求會排隊。
- 分片 model（`-00001-of-00005.gguf` 這種）要選 `00001` 那一片。

## 安全

- 只聽 `127.0.0.1`，只有同一台機器連得到。
- 沒設 API key。要開給別台機器用（`--host 0.0.0.0`）時，記得一起加 `--api-key`。
- llama.cpp 的 Web UI 預設開著，和 API 共用同一個 port。

## 想知道更多

[docs/guide.md](docs/guide.md) 寫了：

- 名詞解釋：mmproj、prefill、slot、context checkpoint
- 每個啟動參數的用途，以及怎麼覆蓋
- 最近使用紀錄存在哪、怎麼更新
- 記憶體實測數字，以及為什麼要設 `MALLOC_MMAP_THRESHOLD_`
- 幾種特殊情況和限制

## 授權

MIT，全文見 [LICENSE](LICENSE)。
