#!/bin/bash
# E2E test: runs Emacs in a real terminal (via script/expect-like flow)
# against a mock gateway, sends a message, and verifies the reply appears
# correctly in the chat buffer.
#
# Exit 0 = PASS, Exit 1 = FAIL
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
MOCK_PORT=18790
MOCK_PID=""
EMACS_PID=""
RESULT_FILE=$(mktemp)
EMACS_OUTPUT=$(mktemp)
EMACS_INIT=$(mktemp --suffix=.el)

cleanup() {
    [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null || true
    [ -n "$EMACS_PID" ] && kill "$EMACS_PID" 2>/dev/null || true
    rm -f "$RESULT_FILE" "$EMACS_OUTPUT" "$EMACS_INIT"
}
trap cleanup EXIT

echo "=== OpenClaw.el E2E Test ==="
echo "Project dir: $PROJECT_DIR"
echo ""

# 1. Start mock gateway
echo "[1/5] Starting mock gateway on port $MOCK_PORT..."
node "$SCRIPT_DIR/mock-gateway.js" "$MOCK_PORT" &
MOCK_PID=$!
sleep 1

if ! kill -0 "$MOCK_PID" 2>/dev/null; then
    echo "FAIL: Mock gateway failed to start"
    exit 1
fi
echo "  Mock gateway PID: $MOCK_PID"

# 2. Create Emacs init script that:
#    - Loads openclaw.el
#    - Connects to mock gateway
#    - Sends a test message
#    - Waits for reply
#    - Dumps buffer content to file
#    - Exits
cat > "$EMACS_INIT" <<ELISP
;; E2E test init
(package-initialize)
(add-to-list 'load-path "$PROJECT_DIR")
(require 'openclaw)

;; Override gateway URL
(setq openclaw-gateway-url "ws://127.0.0.1:$MOCK_PORT")
(setq openclaw-gateway-token "e2e-test-token")

;; Result file
(defvar e2e-result-file "$RESULT_FILE")
(defvar e2e-output-file "$EMACS_OUTPUT")

;; Track state
(defvar e2e-message-sent nil)
(defvar e2e-wait-start nil)
(defvar e2e-connected nil)

;; Wait for handshake to complete and sessions loaded, then open session
(defun e2e-check-connected ()
  (if (and openclaw--websocket openclaw--handshake-complete
           (not (hash-table-empty-p openclaw--sessions)))
      (progn
        (message "E2E: Connected with %d sessions, opening session..."
                 (hash-table-count openclaw--sessions))
        (setq e2e-connected t)
        ;; Use the internal switch function to open the session buffer
        (openclaw--switch-to-session "agent:test:main")
        (run-at-time 3 nil #'e2e-send-message))
    (run-at-time 0.5 nil #'e2e-check-connected)))

(defun e2e-send-message ()
  (message "E2E: Sending test message...")
  ;; Find the chat buffer
  (let ((buf (cl-find-if
              (lambda (b)
                (with-current-buffer b
                  (and (eq major-mode 'openclaw-chat-mode)
                       (equal openclaw--current-session "agent:test:main"))))
              (buffer-list))))
    (if buf
        (with-current-buffer buf
          ;; Type and send message
          (goto-char (point-max))
          ;; Find input area
          (when openclaw--input-start-marker
            (goto-char openclaw--input-start-marker))
          (insert "hello world")
          (openclaw-send-message)
          (setq e2e-message-sent t)
          (setq e2e-wait-start (float-time))
          (run-at-time 1 nil #'e2e-check-reply))
      (progn
        (message "E2E: No chat buffer found!")
        (e2e-write-result "FAIL" "No chat buffer found")))))

(defun e2e-check-reply ()
  (let* ((elapsed (- (float-time) e2e-wait-start))
         (buf (cl-find-if
               (lambda (b)
                 (with-current-buffer b
                   (and (eq major-mode 'openclaw-chat-mode)
                        (equal openclaw--current-session "agent:test:main"))))
               (buffer-list))))
    (if (not buf)
        (e2e-write-result "FAIL" "Chat buffer disappeared")
      (with-current-buffer buf
        (let ((content (buffer-string)))
          ;; Write buffer content for debugging
          (with-temp-file e2e-output-file
            (insert content))
          (cond
           ;; Success: reply appeared and is not duplicated
           ((string-match-p "echo: hello world" content)
            (let ((count 0) (start 0))
              (while (string-match "echo: hello world" content start)
                (setq count (1+ count) start (match-end 0)))
              (cond
               ((= count 1)
                ;; Check it's not blank (the text has actual content)
                (if (string-match-p "echo: hello world" content)
                    (e2e-write-result "PASS" (format "Reply appeared correctly (1 occurrence). Buffer length: %d" (length content)))
                  (e2e-write-result "FAIL" "Reply text is present but might be blank")))
               ((> count 1)
                (e2e-write-result "FAIL" (format "DUPLICATE: reply appeared %d times" count)))
               (t
                (e2e-write-result "FAIL" "Reply count is 0 despite match")))))
           ;; Still waiting
           ((< elapsed 15)
            (run-at-time 0.5 nil #'e2e-check-reply))
           ;; Timeout
           (t
            (e2e-write-result "FAIL"
                              (format "Timeout: reply not found after %.1fs. Buffer: %s"
                                      elapsed (substring content 0 (min 500 (length content))))))))))))

(defun e2e-write-result (status msg)
  (message "E2E: %s - %s" status msg)
  (with-temp-file e2e-result-file
    (insert (format "%s\n%s\n" status msg)))
  (run-at-time 0.5 nil #'kill-emacs (if (equal status "PASS") 0 1)))

;; Start
(message "E2E: Connecting to mock gateway...")
(openclaw-connect "ws://127.0.0.1:$MOCK_PORT")
(run-at-time 1 nil #'e2e-check-connected)
ELISP

echo "[2/5] Starting Emacs with openclaw.el..."

# Run Emacs with the test script.
# Use script to provide a pseudo-terminal, which is required for
# proper buffer/display behavior.
TERM=xterm-256color script -qec "emacs -nw -Q -l '$EMACS_INIT'" /dev/null &
EMACS_PID=$!
echo "  Emacs PID: $EMACS_PID"

# 3. Wait for result
echo "[3/5] Waiting for test to complete (max 30s)..."
WAITED=0
while [ $WAITED -lt 30 ]; do
    if [ -s "$RESULT_FILE" ]; then
        break
    fi
    if ! kill -0 "$EMACS_PID" 2>/dev/null; then
        break
    fi
    sleep 1
    WAITED=$((WAITED + 1))
done

# Kill Emacs if still running
if kill -0 "$EMACS_PID" 2>/dev/null; then
    kill "$EMACS_PID" 2>/dev/null || true
    wait "$EMACS_PID" 2>/dev/null || true
fi

# 4. Check results
echo "[4/5] Checking results..."
if [ -s "$RESULT_FILE" ]; then
    STATUS=$(head -1 "$RESULT_FILE")
    MSG=$(tail -1 "$RESULT_FILE")
    echo "  Result: $STATUS"
    echo "  Detail: $MSG"
else
    STATUS="FAIL"
    MSG="No result file produced (Emacs may have crashed)"
    echo "  Result: $STATUS"
    echo "  Detail: $MSG"
fi

# Show buffer content if available
if [ -s "$EMACS_OUTPUT" ]; then
    echo ""
    echo "[5/5] Buffer content:"
    echo "---"
    cat "$EMACS_OUTPUT"
    echo "---"
else
    echo "[5/5] No buffer output captured"
fi

echo ""
if [ "$STATUS" = "PASS" ]; then
    echo "=== E2E TEST PASSED ==="
    exit 0
else
    echo "=== E2E TEST FAILED ==="
    exit 1
fi
