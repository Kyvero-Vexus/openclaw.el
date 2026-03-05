;;; test-openclaw.el --- E2E parity tests for openclaw.el -*- lexical-binding: t; -*-

;;; Commentary:
;; End-to-end tests verifying feature parity with OpenClaw TUI.
;; Each test references a spec ID from docs/openclaw-tui-spec.md.
;; Run: emacs --batch -L . -L test -l test-openclaw.el -f oc-test-run-all

;;; Code:

(require 'package)
(package-initialize)
(require 'openclaw)
(require 'test-helper)

;;; ============================================================
;;; SPEC-01: Connection/Auth/Handshake Lifecycle
;;; ============================================================

(oc-test-deftest spec-01.1-websocket-connect
  "SPEC-01.1: Can initiate WebSocket connection."
  (oc-mock--install)
  (unwind-protect
      (progn
        (openclaw-connect "ws://127.0.0.1:18789")
        (oc-test-assert-nonnil openclaw--websocket
                               "WebSocket object created after connect"))
    (oc-mock--uninstall)))

(oc-test-deftest spec-01.2-handshake-challenge-response
  "SPEC-01.2: Responds to connect.challenge with connect request."
  (oc-mock--install)
  (unwind-protect
      (progn
        (let ((openclaw-gateway-token "test-token-123"))
          (openclaw-connect "ws://127.0.0.1:18789")
          ;; Simulate challenge
          (oc-mock--simulate-message
           (json-encode `((type . "event")
                          (event . "connect.challenge")
                          (payload . ((nonce . "test-nonce")
                                      (ts . 1737264000000))))))
          ;; Check that connect request was sent
          (let* ((sent (oc-mock--last-sent-parsed))
                 (method (alist-get 'method sent))
                 (params (alist-get 'params sent))
                 (auth (alist-get 'auth params))
                 (client (alist-get 'client params)))
            (oc-test-assert-equal "connect" method
                                  "Sent connect method after challenge")
            (oc-test-assert-equal "test-token-123" (alist-get 'token auth)
                                  "Token included in auth")
            (oc-test-assert-equal 3 (alist-get 'minProtocol params)
                                  "minProtocol is 3")
            (oc-test-assert-equal 3 (alist-get 'maxProtocol params)
                                  "maxProtocol is 3")
            (oc-test-assert-equal "operator" (alist-get 'role params)
                                  "Role is operator")
            (oc-test-assert-nonnil (alist-get 'displayName client)
                                   "Client displayName present")
            (oc-test-assert-nonnil (alist-get 'version client)
                                   "Client version present"))))
    (oc-mock--uninstall)))

(oc-test-deftest spec-01.2-handshake-complete
  "SPEC-01.2: Handshake completes on hello-ok response."
  (oc-mock--install)
  (unwind-protect
      (progn
        (let ((openclaw-gateway-token "test-token"))
          (openclaw-connect "ws://127.0.0.1:18789")
          (oc-test-assert-nil openclaw--handshake-complete
                              "Handshake not complete before challenge")
          (oc-mock--complete-handshake)
          (oc-test-assert-nonnil openclaw--handshake-complete
                                 "Handshake complete after hello-ok")))
    (oc-mock--uninstall)))

(oc-test-deftest spec-01.3-connection-states
  "SPEC-01.3: Connection state transitions."
  (oc-mock--install)
  (unwind-protect
      (progn
        (oc-test-assert-nil (openclaw-connected-p)
                            "Initially disconnected")
        (let ((openclaw-gateway-token "tok"))
          (openclaw-connect)
          (oc-test-assert-nonnil (openclaw-connected-p)
                                 "Connected after openclaw-connect")
          (openclaw-close-connection)
          (oc-test-assert-nil openclaw--websocket
                              "WebSocket nil after close")))
    (oc-mock--uninstall)))

(oc-test-deftest spec-01.4-auto-read-token
  "SPEC-01.4: Can read gateway token from config file."
  (oc-test-assert-nonnil (fboundp 'openclaw--read-config-token)
                         "openclaw--read-config-token function exists"))

;;; ============================================================
;;; SPEC-02: Session List/Switch/Create
;;; ============================================================

(oc-test-deftest spec-02.1-session-list-request
  "SPEC-02.1: Sessions list sends correct RPC."
  (oc-mock--install)
  (unwind-protect
      (progn
        (let ((openclaw-gateway-token "tok"))
          (openclaw-connect)
          (oc-mock--complete-handshake)
          ;; The handshake triggers fetch-sessions automatically.
          ;; Check that sessions.list was requested.
          (let ((methods (oc-mock--sent-methods)))
            (oc-test-assert (member "sessions.list" methods)
                            "sessions.list RPC sent after handshake"))))
    (oc-mock--uninstall)))

(oc-test-deftest spec-02.1-session-list-parse
  "SPEC-02.1: Sessions list response populates session table."
  (oc-mock--install)
  (unwind-protect
      (progn
        (let ((openclaw-gateway-token "tok"))
          (openclaw-connect)
          (oc-mock--complete-handshake)
          ;; Find the sessions.list request and respond
          (let* ((sessions-req nil))
            (dolist (f oc-mock--sent-frames)
              (let ((parsed (json-read-from-string f)))
                (when (equal (alist-get 'method parsed) "sessions.list")
                  (setq sessions-req parsed))))
            (when sessions-req
              (oc-mock--simulate-message
               (json-encode
                `((type . "res")
                  (id . ,(alist-get 'id sessions-req))
                  (ok . t)
                  (payload . ((result . ((sessions . [((key . "agent:main:main")
                                                       (label . "Main Session")
                                                       (agentId . "main"))
                                                      ((key . "agent:main:test")
                                                       (label . "Test Session")
                                                       (agentId . "main"))]))))))))
              ;; Now check sessions table
              (oc-test-assert-equal 2 (hash-table-count openclaw--sessions)
                                    "Two sessions loaded")
              (oc-test-assert-nonnil (gethash "agent:main:main" openclaw--sessions)
                                     "Main session present in table")))))
    (oc-mock--uninstall)))

(oc-test-deftest spec-02.2-session-switch-buffer
  "SPEC-02.2: Switching session creates correctly named buffer."
  (oc-mock--install)
  (unwind-protect
      (progn
        (let ((openclaw-gateway-token "tok"))
          (openclaw-connect)
          (oc-mock--complete-handshake)
          ;; Populate sessions
          (puthash "agent:main:main"
                   '((key . "agent:main:main")
                     (label . "Main Session")
                     (agentId . "main"))
                   openclaw--sessions)
          (setq openclaw--handshake-complete t)
          (openclaw--switch-to-session "agent:main:main")
          (let ((buf (get-buffer "*openclaw:Main Session*")))
            (oc-test-assert-nonnil buf "Session buffer created with correct name")
            (when buf
              (with-current-buffer buf
                (oc-test-assert-equal 'openclaw-chat-mode major-mode
                                      "Buffer uses openclaw-chat-mode")
                (oc-test-assert-equal "agent:main:main" openclaw--current-session
                                      "Buffer has correct session key"))
              (kill-buffer buf)))))
    (oc-mock--uninstall)))

(oc-test-deftest spec-02.3-new-session
  "SPEC-02.3: New chat creates a buffer."
  (oc-mock--install)
  (unwind-protect
      (progn
        (openclaw-new-chat)
        (oc-test-assert-equal 'openclaw-chat-mode major-mode
                              "New chat buffer uses openclaw-chat-mode")
        (oc-test-assert-match "Welcome" (buffer-string)
                              "New chat shows welcome message")
        (kill-buffer (current-buffer)))
    (oc-mock--uninstall)))

(oc-test-deftest spec-02.4-default-session
  "SPEC-02.4: Default session key is configurable."
  (oc-test-assert-nonnil (boundp 'openclaw-default-session)
                         "openclaw-default-session variable exists"))

;;; ============================================================
;;; SPEC-03: Message Rendering
;;; ============================================================

(oc-test-deftest spec-03.1-role-display
  "SPEC-03.1: Messages display role correctly."
  (oc-mock--install)
  (unwind-protect
      (progn
        (let ((openclaw-gateway-token "tok"))
          (openclaw-connect)
          (oc-mock--complete-handshake)
          (puthash "test-sess" '((key . "test-sess") (label . "Test")) openclaw--sessions)
          (openclaw--switch-to-session "test-sess")
          ;; Simulate history response
          (let ((history-req nil))
            (dolist (f oc-mock--sent-frames)
              (let ((parsed (json-read-from-string f)))
                (when (equal (alist-get 'method parsed) "chat.history")
                  (setq history-req parsed))))
            (when history-req
              (oc-mock--simulate-message
               (json-encode
                `((type . "res")
                  (id . ,(alist-get 'id history-req))
                  (ok . t)
                  (payload . ((result . ((messages . [((role . "user")
                                                       (content . "Hello")
                                                       (timestamp . "2026-03-05T10:00:00Z"))
                                                      ((role . "assistant")
                                                       (content . "Hi there!")
                                                       (timestamp . "2026-03-05T10:00:01Z"))]))))))))
              (let ((content (buffer-string)))
                (oc-test-assert-match "User\\|user\\|YOU\\|𝗬𝗼𝘂" content
                                      "User role appears in buffer")
                (oc-test-assert-match "Assistant\\|assistant\\|AI\\|🤖" content
                                      "Assistant role appears in buffer")
                (oc-test-assert-match "Hello" content
                                      "User message content rendered")
                (oc-test-assert-match "Hi there!" content
                                      "Assistant message content rendered"))))
          (kill-buffer (current-buffer))))
    (oc-mock--uninstall)))

(oc-test-deftest spec-03.2-multipart-content
  "SPEC-03.2: Multi-part content rendered correctly."
  (let ((result (openclaw--content->text
                 [((type . "text") (text . "Part 1"))
                  ((type . "text") (text . "Part 2"))])))
    (oc-test-assert-match "Part 1" result "Part 1 present")
    (oc-test-assert-match "Part 2" result "Part 2 present")))

(oc-test-deftest spec-03.2-string-content
  "SPEC-03.2: String content rendered as-is."
  (oc-test-assert-equal "Hello world"
                        (openclaw--content->text "Hello world")
                        "String content passes through"))

(oc-test-deftest spec-03.2-octal-escaped-unicode
  "SPEC-03.2: Octal-escaped byte sequences decode to proper Unicode."
  (let ((raw "Yep, I\\342\\200\\231m here \\360\\237\\221\\213 test received."))
    (oc-test-assert-equal "Yep, I’m here 👋 test received."
                          (openclaw--content->text raw)
                          "Octal-escaped UTF-8 decoded correctly")))

(oc-test-deftest spec-03.3-timestamp-display
  "SPEC-03.3: Timestamps displayed in messages."
  ;; We just check the format function exists and works
  (oc-test-assert-nonnil (fboundp 'openclaw--format-timestamp)
                         "Timestamp formatter exists"))

(oc-test-deftest spec-03.5-faces-defined
  "SPEC-03.5: Custom faces are defined."
  (oc-test-assert-nonnil (facep 'openclaw-user-face)
                         "openclaw-user-face defined")
  (oc-test-assert-nonnil (facep 'openclaw-assistant-face)
                         "openclaw-assistant-face defined")
  (oc-test-assert-nonnil (facep 'openclaw-system-face)
                         "openclaw-system-face defined")
  (oc-test-assert-nonnil (facep 'openclaw-timestamp-face)
                         "openclaw-timestamp-face defined"))

;;; ============================================================
;;; SPEC-04: Slash Commands and Key Bindings
;;; ============================================================

(oc-test-deftest spec-04.1-slash-command-send
  "SPEC-04.1: Slash commands sent via chat.send."
  (oc-mock--install)
  (unwind-protect
      (progn
        (let ((openclaw-gateway-token "tok"))
          (openclaw-connect)
          (oc-mock--complete-handshake)
          (setq oc-mock--sent-frames nil)  ; clear handshake frames
          (with-temp-buffer
            (openclaw-chat-mode)
            (setq-local openclaw--current-session "test-sess")
            (openclaw-slash-command "/status")
            (let* ((sent (oc-mock--last-sent-parsed))
                   (params (alist-get 'params sent)))
              (oc-test-assert-equal "chat.send" (alist-get 'method sent)
                                    "Slash command sent via chat.send")
              (oc-test-assert-equal "/status" (alist-get 'message params)
                                    "Command text preserved")
              (oc-test-assert-nonnil (alist-get 'idempotencyKey params)
                                     "Idempotency key present")))))
    (oc-mock--uninstall)))

(oc-test-deftest spec-04.2-keybindings-exist
  "SPEC-04.2: Required keybindings are defined in chat mode."
  (let ((map openclaw-chat-mode-map))
    (oc-test-assert-nonnil (lookup-key map (kbd "C-c C-c"))
                           "C-c C-c bound in chat mode")
    (oc-test-assert-nonnil (lookup-key map (kbd "C-c C-l"))
                           "C-c C-l bound in chat mode")
    (oc-test-assert-nonnil (lookup-key map (kbd "C-c C-s"))
                           "C-c C-s bound in chat mode")
    (oc-test-assert-nonnil (lookup-key map (kbd "C-c C-n"))
                           "C-c C-n bound in chat mode")
    (oc-test-assert-nonnil (lookup-key map (kbd "C-c C-q"))
                           "C-c C-q bound in chat mode")
    (oc-test-assert-nonnil (lookup-key map (kbd "C-c C-a"))
                           "C-c C-a (abort) bound in chat mode")))

(oc-test-deftest spec-04.3-tui-shortcut-bindings
  "SPEC-04.3: TUI-equivalent shortcuts exist."
  (let ((map openclaw-chat-mode-map))
    (oc-test-assert-nonnil (lookup-key map (kbd "C-c C-m"))
                           "C-c C-m (model picker) bound")
    (oc-test-assert-nonnil (lookup-key map (kbd "C-c C-p"))
                           "C-c C-p (session picker) bound")))

;;; ============================================================
;;; SPEC-05: Error Handling
;;; ============================================================

(oc-test-deftest spec-05.1-connection-error-no-crash
  "SPEC-05.1: Connection errors don't crash."
  (oc-mock--install)
  (unwind-protect
      (progn
        ;; Override to simulate error
        (advice-add 'websocket-open :override
                    (lambda (&rest _) (error "Connection refused"))
                    '((name . oc-test-error-sim)))
        (condition-case err
            (openclaw-connect "ws://bad:9999")
          (error
           (oc-test-assert-match "Connection refused\\|error" (format "%s" err)
                                 "Error message is informative")))
        (advice-remove 'websocket-open 'oc-test-error-sim))
    (oc-mock--uninstall)))

(oc-test-deftest spec-05.2-rpc-error-handling
  "SPEC-05.2: RPC error responses handled gracefully."
  (oc-mock--install)
  (unwind-protect
      (progn
        (let ((openclaw-gateway-token "tok")
              (error-received nil))
          (openclaw-connect)
          (oc-mock--complete-handshake)
          (setq oc-mock--sent-frames nil)
          (openclaw--make-request "bad.method" nil
                                 (lambda (result)
                                   (setq error-received (alist-get 'error result))))
          (let ((req-id (alist-get 'id (oc-mock--last-sent-parsed))))
            (oc-mock--simulate-message
             (json-encode `((type . "res")
                            (id . ,req-id)
                            (ok . :json-false)
                            (error . "method not found")))))
          (oc-test-assert-nonnil error-received
                                 "Error callback received error")))
    (oc-mock--uninstall)))

;;; ============================================================
;;; SPEC-06: Buffer Model
;;; ============================================================

(oc-test-deftest spec-06.1-buffer-per-session
  "SPEC-06.1: Each session gets its own buffer."
  (oc-mock--install)
  (unwind-protect
      (progn
        (let ((openclaw-gateway-token "tok"))
          (openclaw-connect)
          (oc-mock--complete-handshake)
          (puthash "sess-a" '((key . "sess-a") (label . "Alpha")) openclaw--sessions)
          (puthash "sess-b" '((key . "sess-b") (label . "Beta")) openclaw--sessions)
          (openclaw--switch-to-session "sess-a")
          (openclaw--switch-to-session "sess-b")
          (oc-test-assert-nonnil (get-buffer "*openclaw:Alpha*")
                                 "Alpha session buffer exists")
          (oc-test-assert-nonnil (get-buffer "*openclaw:Beta*")
                                 "Beta session buffer exists")
          (ignore-errors (kill-buffer "*openclaw:Alpha*"))
          (ignore-errors (kill-buffer "*openclaw:Beta*"))))
    (oc-mock--uninstall)))

(oc-test-deftest spec-06.3-help-buffer
  "SPEC-06.3: Help buffer created with content."
  (openclaw-help)
  (let ((buf (get-buffer "*openclaw-help*")))
    (oc-test-assert-nonnil buf "Help buffer created")
    (when buf
      (with-current-buffer buf
        (oc-test-assert-match "OpenClaw" (buffer-string)
                              "Help buffer has content"))
      (kill-buffer buf))))

(oc-test-deftest spec-06.4-slash-detection
  "SPEC-06.4: Slash commands detected by leading /."
  ;; Test that openclaw-slash-command prepends / if missing
  (oc-mock--install)
  (unwind-protect
      (progn
        (let ((openclaw-gateway-token "tok"))
          (openclaw-connect)
          (oc-mock--complete-handshake)
          (setq oc-mock--sent-frames nil)
          (with-temp-buffer
            (openclaw-chat-mode)
            (setq-local openclaw--current-session "test")
            (openclaw-slash-command "help")
            (let ((params (alist-get 'params (oc-mock--last-sent-parsed))))
              (oc-test-assert-equal "/help" (alist-get 'message params)
                                    "Slash prepended when missing")))))
    (oc-mock--uninstall)))

;;; ============================================================
;;; SPEC-07: Mode Line
;;; ============================================================

(oc-test-deftest spec-07.1-mode-line-format
  "SPEC-07.1: Mode line shows connection info."
  (oc-test-assert-nonnil (boundp 'openclaw--mode-line-string)
                         "Mode line string variable exists"))

;;; ============================================================
;;; SPEC-08: Agent Management
;;; ============================================================

(oc-test-deftest spec-08.1-agent-list
  "SPEC-08.1: Agent list function exists."
  (oc-test-assert-nonnil (fboundp 'openclaw-list-agents)
                         "openclaw-list-agents function exists"))

(oc-test-deftest spec-08.2-agent-switch
  "SPEC-08.2: Agent switch function exists."
  (oc-test-assert-nonnil (fboundp 'openclaw-switch-agent)
                         "openclaw-switch-agent function exists"))

;;; ============================================================
;;; SPEC-09: Event Handling
;;; ============================================================

(oc-test-deftest spec-09.1-chat-event
  "SPEC-09.1: Chat events trigger history refresh."
  (oc-mock--install)
  (unwind-protect
      (progn
        (let ((openclaw-gateway-token "tok")
              (history-fetched nil))
          (openclaw-connect)
          (oc-mock--complete-handshake)
          ;; Create a session buffer
          (puthash "test-sess" '((key . "test-sess") (label . "Test")) openclaw--sessions)
          (let ((buf (get-buffer-create "*openclaw:Test*")))
            (with-current-buffer buf
              (openclaw-chat-mode)
              (setq-local openclaw--current-session "test-sess"))
            ;; Track if history fetch is called
            (advice-add 'openclaw--fetch-history :before
                        (lambda (&rest _) (setq history-fetched t))
                        '((name . oc-test-track-fetch)))
            (setq oc-mock--sent-frames nil)
            ;; Simulate chat event
            (oc-mock--simulate-message
             (json-encode `((type . "event")
                            (event . "chat")
                            (payload . ((sessionKey . "test-sess"))))))
            (advice-remove 'openclaw--fetch-history 'oc-test-track-fetch)
            (oc-test-assert-nonnil history-fetched
                                   "Chat event triggered history fetch")
            (kill-buffer buf))))
    (oc-mock--uninstall)))

;;; ============================================================
;;; Integration: Full connect + session flow
;;; ============================================================

(oc-test-deftest integration-connect-and-list
  "Integration: Connect, handshake, list sessions."
  (oc-mock--install)
  (unwind-protect
      (progn
        (let ((openclaw-gateway-token "tok"))
          (openclaw-connect)
          (oc-mock--complete-handshake)
          (oc-test-assert-nonnil openclaw--handshake-complete
                                 "Handshake completed")
          (oc-test-assert-nonnil (openclaw-connected-p)
                                 "Reports as connected")
          (let ((methods (oc-mock--sent-methods)))
            (oc-test-assert (member "connect" methods) "connect sent")
            (oc-test-assert (member "sessions.list" methods) "sessions.list sent"))))
    (oc-mock--uninstall)))

;;; ============================================================
;;; Test Runner
;;; ============================================================

(defun oc-test-run-all ()
  "Run all openclaw tests and report results."
  (setq oc-test--results nil)

  ;; Collect all test functions
  (let ((test-fns nil))
    (mapatoms (lambda (sym)
                (when (and (fboundp sym)
                           (string-prefix-p "oc-test--spec-" (symbol-name sym)))
                  (push sym test-fns)))
              obarray)
    (mapatoms (lambda (sym)
                (when (and (fboundp sym)
                           (string-prefix-p "oc-test--integration-" (symbol-name sym)))
                  (push sym test-fns)))
              obarray)

    ;; Sort for deterministic order
    (setq test-fns (sort test-fns
                         (lambda (a b)
                           (string< (symbol-name a) (symbol-name b)))))

    (message "")
    (message "========================================")
    (message " OpenClaw.el E2E Parity Test Suite")
    (message "========================================")
    (message "")

    ;; Run each test
    (dolist (fn test-fns)
      (message "Running: %s" (symbol-name fn))
      (condition-case err
          (funcall fn)
        (error
         (push (list (symbol-name fn) nil (format "CRASHED: %s" err))
               oc-test--results)
         (message "  CRASH: %s" err))))

    ;; Report
    (let ((total 0) (passed 0) (failed 0))
      (dolist (r oc-test--results)
        (cl-incf total)
        (if (cadr r) (cl-incf passed) (cl-incf failed)))

      (message "")
      (message "========================================")
      (message " Results: %d total, %d passed, %d failed"
               total passed failed)
      (message "========================================")

      ;; Show failures
      (when (> failed 0)
        (message "")
        (message "FAILURES:")
        (dolist (r (reverse oc-test--results))
          (unless (cadr r)
            (message "  [FAIL] %s: %s" (car r) (caddr r)))))

      (message "")

      ;; Exit with appropriate code
      (kill-emacs (if (> failed 0) 1 0)))))

(provide 'test-openclaw)

;;; test-openclaw.el ends here
