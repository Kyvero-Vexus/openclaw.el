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
          (let ((buf (get-buffer "*agent:main:main*")))
            (oc-test-assert-nonnil buf "Session buffer created with session-key name")
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

(oc-test-deftest spec-03.6-assistant-label-uses-agent-name
  "SPEC-03.6: Assistant label uses agent name from session key."
  (with-temp-buffer
    (openclaw-chat-mode)
    (setq-local openclaw--current-session "agent:ceo_chryso:main")
    (openclaw--insert-input-area "")
    (openclaw--handle-chat-message
     '((sessionKey . "agent:ceo_chryso:main")
       (role . "assistant")
       (content . "hello")))
    (let ((txt (buffer-string)))
      (oc-test-assert-match "ceo_chryso:" txt
                            "Assistant messages show agent name label"))))

(oc-test-deftest spec-03.7-markdown-rendering
  "SPEC-03.7: Markdown gets font-lock style properties."
  (with-temp-buffer
    (openclaw-chat-mode)
    (openclaw--insert-input-area "")
    (openclaw--insert-message-before-input
     "Assistant: " 'openclaw-assistant-face "**bold** and `code`")
    (goto-char (point-min))
    (search-forward "bold")
    (let ((bold-face (get-text-property (1- (point)) 'face)))
      (oc-test-assert-nonnil bold-face "Bold markdown has face property"))
    (search-forward "code")
    (let ((code-face (get-text-property (1- (point)) 'face)))
      (oc-test-assert-nonnil code-face "Code markdown has face property"))))

(oc-test-deftest spec-03.8-inline-image-render-call
  "SPEC-03.8: Inline image URLs attempt image insertion."
  (let ((img-called nil)
        (insert-called nil))
    (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) t))
              ((symbol-function 'create-image)
               (lambda (&rest _args) (setq img-called t) 'mock-image))
              ((symbol-function 'insert-image)
               (lambda (&rest _args) (setq insert-called t))))
      (with-temp-buffer
        (openclaw--insert-rendered-content "![alt](https://x.test/a.svg)")
        (oc-test-assert img-called "create-image invoked for inline image")
        (oc-test-assert insert-called "insert-image invoked for inline image")))))

(oc-test-deftest spec-03.9-heartbeat-comment-face
  "SPEC-03.9: Heartbeat text is shown with comment face."
  (with-temp-buffer
    (openclaw-chat-mode)
    (openclaw--insert-input-area "")
    (openclaw--insert-message-before-input
     "System: " 'openclaw-system-face "HEARTBEAT_OK")
    (goto-char (point-min))
    (search-forward "HEARTBEAT_OK")
    (let ((face (get-text-property (1- (point)) 'face)))
      (oc-test-assert face "Heartbeat text has a face")
      (oc-test-assert (or (eq face 'font-lock-comment-face)
                          (and (listp face) (memq 'font-lock-comment-face face)))
                      "Heartbeat uses comment-like styling"))))

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
          (oc-test-assert-nonnil (get-buffer "*sess-a*")
                                 "sess-a session buffer exists")
          (oc-test-assert-nonnil (get-buffer "*sess-b*")
                                 "sess-b session buffer exists")
          (ignore-errors (kill-buffer "*sess-a*"))
          (ignore-errors (kill-buffer "*sess-b*"))))
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

(oc-test-deftest spec-06.5-input-box-send-not-empty
  "SPEC-06.5: Text typed in input box is sent (not treated as empty)."
  (oc-mock--install)
  (unwind-protect
      (progn
        (let ((openclaw-gateway-token "tok"))
          (openclaw-connect)
          (oc-mock--complete-handshake)
          (setq oc-mock--sent-frames nil)
          (with-temp-buffer
            (openclaw-chat-mode)
            (setq-local openclaw--current-session "test-sess")
            (openclaw--insert-input-area "")
            (goto-char (point-max))
            (insert "test")
            (openclaw-send-message)
            (let* ((sent (oc-mock--last-sent-parsed))
                   (params (alist-get 'params sent)))
              (oc-test-assert-equal "chat.send" (alist-get 'method sent)
                                    "chat.send request emitted")
              (oc-test-assert-equal "test" (alist-get 'message params)
                                    "Typed input text sent")
              (oc-test-assert-equal "" (openclaw--input-text)
                                    "Input box cleared after send")))))
    (oc-mock--uninstall)))

(oc-test-deftest spec-06.6-ret-bound-to-send
  "SPEC-06.6: RET in chat mode is bound to send from input box."
  (oc-test-assert-equal #'openclaw-send-message
                        (lookup-key openclaw-chat-mode-map (kbd "RET"))
                        "RET sends current input box"))

(oc-test-deftest spec-06.7-status-bar-content
  "SPEC-06.7: Input separator status line includes connection/agent/session info."
  (cl-letf (((symbol-function 'openclaw-connected-p) (lambda () t)))
    (with-temp-buffer
      (openclaw-chat-mode)
      (setq-local openclaw--current-session "agent:ceo_chryso:main")
      (setq openclaw--current-agent "ceo_chryso")
      (setq-local openclaw--run-state 'idle)
      (openclaw--insert-input-area "")
      (let ((txt (buffer-string)))
        (oc-test-assert-match "connected" txt "Status bar shows connection")
        (oc-test-assert-match "idle" txt "Status bar shows idle state")
        (oc-test-assert-match "agent:ceo_chryso" txt "Status bar shows agent")
        (oc-test-assert-match "session:agent:ceo_chryso:main" txt
                              "Status bar shows current session")))))

(oc-test-deftest spec-06.7b-status-bar-thinking-idle-transition
  "SPEC-06.7b: Status bar shows thinking after send, idle after assistant reply."
  (oc-mock--install)
  (unwind-protect
      (let ((openclaw-gateway-token "tok"))
        (openclaw-connect)
        (oc-mock--complete-handshake)
        (setq oc-mock--sent-frames nil)
        (with-temp-buffer
          (openclaw-chat-mode)
          (setq-local openclaw--current-session "agent:ceo_chryso:main")
          (setq openclaw--current-agent "ceo_chryso")
          (openclaw--insert-input-area "")
          (goto-char (point-max))
          (insert "test")
          (openclaw-send-message)
          (oc-test-assert-equal 'thinking openclaw--run-state
                                "Run state set to thinking after send")
          (oc-test-assert-match "thinking" (buffer-string)
                                "Status bar text shows thinking")
          (openclaw--handle-chat-message
           '((sessionKey . "agent:ceo_chryso:main")
             (role . "assistant")
             (content . "done")))
          (oc-test-assert-equal 'idle openclaw--run-state
                                "Run state set to idle on assistant message")
          (oc-test-assert-match "idle" (buffer-string)
                                "Status bar text shows idle")))
    (oc-mock--uninstall)))

(oc-test-deftest spec-06.8-heartbeat-does-not-break-chat
  "SPEC-06.8: Heartbeat rendering does not break subsequent sending."
  (oc-mock--install)
  (unwind-protect
      (let ((openclaw-gateway-token "tok"))
        (openclaw-connect)
        (oc-mock--complete-handshake)
        (setq oc-mock--sent-frames nil)
        (with-temp-buffer
          (openclaw-chat-mode)
          (setq-local openclaw--current-session "agent:ceo_chryso:main")
          (openclaw--insert-input-area "")
          (openclaw--handle-chat-message
           '((sessionKey . "agent:ceo_chryso:main")
             (role . "system")
             (content . "HEARTBEAT_OK")))
          (goto-char (point-max))
          (insert "test")
          (openclaw-send-message)
          (let* ((sent (oc-mock--last-sent-parsed))
                 (params (alist-get 'params sent)))
            (oc-test-assert-equal "chat.send" (alist-get 'method sent)
                                  "Can still send after heartbeat")
            (oc-test-assert-equal "test" (alist-get 'message params)
                                  "Post-heartbeat input sends correctly"))))
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
;;; SPEC-10: Reconnection
;;; ============================================================

(oc-test-deftest spec-10.1-reconnect-on-close
  "SPEC-10.1: Auto-reconnect schedules after connection close."
  (oc-mock--install)
  (unwind-protect
      (let ((openclaw-gateway-token "tok")
            (openclaw-auto-reconnect t)
            (openclaw-reconnect-base-delay 0.1)
            (scheduled nil))
        (openclaw-connect "ws://127.0.0.1:18789")
        (oc-mock--complete-handshake)
        ;; Verify reconnect URL is stored
        (oc-test-assert-equal "ws://127.0.0.1:18789" openclaw--reconnect-url
                              "Reconnect URL stored after connect")
        ;; Simulate connection drop
        (advice-add 'run-at-time :override
                    (lambda (delay _repeat fn &rest _args)
                      (setq scheduled delay)
                      nil)
                    '((name . oc-test-timer-spy)))
        (setq openclaw--reconnect-url "ws://127.0.0.1:18789")
        (openclaw--on-close nil)
        (advice-remove 'run-at-time 'oc-test-timer-spy)
        (oc-test-assert-nonnil scheduled
                               "Reconnect timer scheduled after close")
        (oc-test-assert (and (numberp scheduled) (> scheduled 0))
                        "Reconnect delay is positive"))
    (openclaw--cancel-reconnect)
    (oc-mock--uninstall)))

(oc-test-deftest spec-10.2-no-reconnect-on-explicit-close
  "SPEC-10.2: Explicit close does not auto-reconnect."
  (oc-mock--install)
  (unwind-protect
      (let ((openclaw-gateway-token "tok")
            (openclaw-auto-reconnect t))
        (openclaw-connect "ws://127.0.0.1:18789")
        (oc-mock--complete-handshake)
        (openclaw-close-connection)
        (oc-test-assert-nil openclaw--reconnect-url
                            "Reconnect URL cleared after explicit close")
        (oc-test-assert-nil openclaw--reconnect-timer
                            "No reconnect timer after explicit close"))
    (openclaw--cancel-reconnect)
    (oc-mock--uninstall)))

(oc-test-deftest spec-10.3-exponential-backoff
  "SPEC-10.3: Reconnect delay grows exponentially."
  (let ((openclaw-reconnect-base-delay 1.0)
        (openclaw-reconnect-max-delay 60.0))
    (setq openclaw--reconnect-attempts 0)
    (let ((d0 (openclaw--reconnect-delay)))
      (oc-test-assert-equal 1.0 d0 "First attempt delay is base"))
    (setq openclaw--reconnect-attempts 3)
    (let ((d3 (openclaw--reconnect-delay)))
      (oc-test-assert-equal 8.0 d3 "Attempt 3 delay is 8s"))
    (setq openclaw--reconnect-attempts 20)
    (let ((d20 (openclaw--reconnect-delay)))
      (oc-test-assert-equal 60.0 d20 "Delay capped at max"))))

(oc-test-deftest spec-10.4-reconnect-resets-on-success
  "SPEC-10.4: Reconnect attempts reset on successful open."
  (oc-mock--install)
  (unwind-protect
      (let ((openclaw-gateway-token "tok"))
        (setq openclaw--reconnect-attempts 5)
        (openclaw-connect "ws://127.0.0.1:18789")
        (oc-test-assert-equal 0 openclaw--reconnect-attempts
                              "Reconnect attempts reset on open"))
    (openclaw--cancel-reconnect)
    (oc-mock--uninstall)))

(oc-test-deftest spec-10.5-idle-then-send
  "SPEC-10.5: Can send message after idle reconnection."
  (oc-mock--install)
  (unwind-protect
      (let ((openclaw-gateway-token "tok")
            (openclaw-auto-reconnect nil))
        (openclaw-connect "ws://127.0.0.1:18789")
        (oc-mock--complete-handshake)
        (setq oc-mock--sent-frames nil)
        (with-temp-buffer
          (openclaw-chat-mode)
          (setq-local openclaw--current-session "test-sess")
          (openclaw--insert-input-area "")
          ;; Simulate connection drop and immediate reconnect
          (setq openclaw--websocket nil
                openclaw--handshake-complete nil)
          ;; Reconnect
          (openclaw-connect "ws://127.0.0.1:18789")
          (oc-mock--complete-handshake)
          (setq oc-mock--sent-frames nil)
          ;; Now send
          (goto-char (point-max))
          (insert "hello after idle")
          (openclaw-send-message)
          (let* ((sent (oc-mock--last-sent-parsed))
                 (params (alist-get 'params sent)))
            (oc-test-assert-equal "chat.send" (alist-get 'method sent)
                                  "chat.send sent after reconnect")
            (oc-test-assert-equal "hello after idle" (alist-get 'message params)
                                  "Message text correct after idle reconnect"))))
    (openclaw--cancel-reconnect)
    (oc-mock--uninstall)))

;;; ============================================================
;;; SPEC-11: Streaming / Delta Handling
;;; ============================================================

(oc-test-deftest spec-11.1-delta-no-refetch
  "SPEC-11.1: Chat event with state=delta does NOT trigger history fetch."
  (oc-mock--install)
  (unwind-protect
      (let ((openclaw-gateway-token "tok")
            (history-fetched nil))
        (openclaw-connect "ws://127.0.0.1:18789")
        (oc-mock--complete-handshake)
        (puthash "test-sess" '((key . "test-sess")) openclaw--sessions)
        (let ((buf (get-buffer-create "*test-sess*")))
          (with-current-buffer buf
            (openclaw-chat-mode)
            (setq-local openclaw--current-session "test-sess")
            (openclaw--insert-input-area ""))
          (advice-add 'openclaw--fetch-history :before
                      (lambda (&rest _) (setq history-fetched t))
                      '((name . oc-test-track-delta-fetch)))
          (setq oc-mock--sent-frames nil)
          (oc-mock--simulate-message
           (json-encode `((type . "event")
                          (event . "chat")
                          (payload . ((sessionKey . "test-sess")
                                      (state . "delta")
                                      (delta . "Hello"))))))
          (advice-remove 'openclaw--fetch-history 'oc-test-track-delta-fetch)
          (oc-test-assert-nil history-fetched
                              "Delta event did NOT trigger history fetch")
          (with-current-buffer buf
            (oc-test-assert-match "Hello" (buffer-string)
                                  "Delta text appears in buffer"))
          (kill-buffer buf)))
    (oc-mock--uninstall)))

(oc-test-deftest spec-11.2-streaming-accumulates
  "SPEC-11.2: Multiple deltas accumulate in buffer."
  (oc-mock--install)
  (unwind-protect
      (let ((openclaw-gateway-token "tok"))
        (openclaw-connect "ws://127.0.0.1:18789")
        (oc-mock--complete-handshake)
        (let ((buf (get-buffer-create "*stream-test*")))
          (with-current-buffer buf
            (openclaw-chat-mode)
            (setq-local openclaw--current-session "stream-sess")
            (openclaw--insert-input-area ""))
          ;; Send three deltas
          (dolist (chunk '("Hello" " world" "!"))
            (oc-mock--simulate-message
             (json-encode `((type . "event")
                            (event . "chat")
                            (payload . ((sessionKey . "stream-sess")
                                        (state . "delta")
                                        (delta . ,chunk)))))))
          (with-current-buffer buf
            (oc-test-assert-match "Hello world!" (buffer-string)
                                  "All deltas accumulated")
            (oc-test-assert-equal "Hello world!" openclaw--streaming-text
                                  "Streaming text variable tracks accumulated content"))
          (kill-buffer buf)))
    (oc-mock--uninstall)))

(oc-test-deftest spec-11.2b-streaming-does-not-overwrite-with-status
  "SPEC-11.2b: Streaming text is preserved and status bar is not duplicated."
  (oc-mock--install)
  (unwind-protect
      (let ((openclaw-gateway-token "tok"))
        (openclaw-connect "ws://127.0.0.1:18789")
        (oc-mock--complete-handshake)
        (let ((buf (get-buffer-create "*stream-status-test*")))
          (with-current-buffer buf
            (openclaw-chat-mode)
            (setq openclaw--current-agent "main")
            (setq-local openclaw--current-session "agent:main:main")
            (openclaw--insert-input-area ""))
          (dolist (chunk '("hi" " there"))
            (oc-mock--simulate-message
             (json-encode `((type . "event")
                            (event . "chat")
                            (payload . ((sessionKey . "agent:main:main")
                                        (state . "delta")
                                        (delta . ,chunk)))))))
          (oc-mock--simulate-message
           (json-encode `((type . "event")
                          (event . "chat")
                          (payload . ((sessionKey . "agent:main:main")
                                      (state . "final")
                                      (content . "hi there"))))))
          (with-current-buffer buf
            (let* ((content (buffer-string))
                   (needle "send: RET / C-c C-c")
                   (count 0)
                   (start 0))
              (oc-test-assert-match "main: hi there" content
                                    "Assistant streamed text remains visible")
              (while (string-match (regexp-quote needle) content start)
                (setq count (1+ count)
                      start (match-end 0)))
              (oc-test-assert-equal 1 count
                                    "Exactly one status bar line remains")))
          (kill-buffer buf)))
    (oc-mock--uninstall)))

(oc-test-deftest spec-11.3-final-resets-state
  "SPEC-11.3: state=final resets streaming and sets idle."
  (oc-mock--install)
  (unwind-protect
      (let ((openclaw-gateway-token "tok"))
        (openclaw-connect "ws://127.0.0.1:18789")
        (oc-mock--complete-handshake)
        (let ((buf (get-buffer-create "*final-test*")))
          (with-current-buffer buf
            (openclaw-chat-mode)
            (setq-local openclaw--current-session "final-sess")
            (openclaw--insert-input-area ""))
          ;; Delta then final
          (oc-mock--simulate-message
           (json-encode `((type . "event")
                          (event . "chat")
                          (payload . ((sessionKey . "final-sess")
                                      (state . "delta")
                                      (delta . "thinking..."))))))
          (with-current-buffer buf
            (oc-test-assert-equal 'thinking openclaw--run-state
                                  "State is thinking during streaming"))
          (oc-mock--simulate-message
           (json-encode `((type . "event")
                          (event . "chat")
                          (payload . ((sessionKey . "final-sess")
                                      (state . "final")
                                      (content . "thinking..."))))))
          (with-current-buffer buf
            (oc-test-assert-equal 'idle openclaw--run-state
                                  "State is idle after final")
            (oc-test-assert-equal "" openclaw--streaming-text
                                  "Streaming text reset after final")
            (oc-test-assert-nil openclaw--streaming-marker
                                "Streaming marker cleared after final"))
          (kill-buffer buf)))
    (oc-mock--uninstall)))

(oc-test-deftest spec-11.4-error-state-handled
  "SPEC-11.4: state=error shows error and resets to idle."
  (oc-mock--install)
  (unwind-protect
      (let ((openclaw-gateway-token "tok"))
        (openclaw-connect "ws://127.0.0.1:18789")
        (oc-mock--complete-handshake)
        (let ((buf (get-buffer-create "*error-test*")))
          (with-current-buffer buf
            (openclaw-chat-mode)
            (setq-local openclaw--current-session "err-sess")
            (openclaw--insert-input-area ""))
          (oc-mock--simulate-message
           (json-encode `((type . "event")
                          (event . "chat")
                          (payload . ((sessionKey . "err-sess")
                                      (state . "error")
                                      (error . "rate limit exceeded"))))))
          (with-current-buffer buf
            (oc-test-assert-equal 'idle openclaw--run-state
                                  "State is idle after error")
            (oc-test-assert-match "rate limit exceeded" (buffer-string)
                                  "Error message displayed in buffer"))
          (kill-buffer buf)))
    (oc-mock--uninstall)))

(oc-test-deftest spec-11.5-legacy-chat-event-fetches-history
  "SPEC-11.5: Chat event without state falls back to history fetch."
  (oc-mock--install)
  (unwind-protect
      (let ((openclaw-gateway-token "tok")
            (history-fetched nil))
        (openclaw-connect "ws://127.0.0.1:18789")
        (oc-mock--complete-handshake)
        (advice-add 'openclaw--fetch-history :before
                    (lambda (&rest _) (setq history-fetched t))
                    '((name . oc-test-track-legacy-fetch)))
        (oc-mock--simulate-message
         (json-encode `((type . "event")
                        (event . "chat")
                        (payload . ((sessionKey . "some-sess"))))))
        (advice-remove 'openclaw--fetch-history 'oc-test-track-legacy-fetch)
        (oc-test-assert-nonnil history-fetched
                               "Legacy chat event triggers history fetch"))
    (oc-mock--uninstall)))

(oc-test-deftest spec-11.6-send-after-long-stream
  "SPEC-11.6: Can send new message after long streaming (think) completes."
  (oc-mock--install)
  (unwind-protect
      (let ((openclaw-gateway-token "tok"))
        (openclaw-connect "ws://127.0.0.1:18789")
        (oc-mock--complete-handshake)
        (setq oc-mock--sent-frames nil)
        (let ((buf (get-buffer-create "*long-stream*")))
          (with-current-buffer buf
            (openclaw-chat-mode)
            (setq-local openclaw--current-session "think-sess")
            (openclaw--insert-input-area ""))
          ;; Simulate a long stream (many deltas + final)
          (dotimes (i 20)
            (oc-mock--simulate-message
             (json-encode `((type . "event")
                            (event . "chat")
                            (payload . ((sessionKey . "think-sess")
                                        (state . "delta")
                                        (delta . ,(format "chunk-%d " i))))))))
          (oc-mock--simulate-message
           (json-encode `((type . "event")
                          (event . "chat")
                          (payload . ((sessionKey . "think-sess")
                                      (state . "final")
                                      (content . "full response"))))))
          ;; Now send a new message
          (with-current-buffer buf
            (oc-test-assert-equal 'idle openclaw--run-state
                                  "State is idle after long stream final")
            (goto-char (point-max))
            (insert "follow-up")
            (setq oc-mock--sent-frames nil)
            (openclaw-send-message)
            (let* ((sent (oc-mock--last-sent-parsed))
                   (params (alist-get 'params sent)))
              (oc-test-assert-equal "chat.send" (alist-get 'method sent)
                                    "chat.send sent after long stream")
              (oc-test-assert-equal "follow-up" (alist-get 'message params)
                                    "Message text correct after long stream")))
          (kill-buffer buf)))
    (oc-mock--uninstall)))

;;; ============================================================
;;; SPEC-12: Streaming State Reset on Disconnect/Reconnect
;;; ============================================================

(oc-test-deftest spec-12.1-disconnect-mid-stream-resets-state
  "SPEC-12.1: Disconnect mid-stream resets streaming state and marks interrupted."
  (oc-mock--install)
  (unwind-protect
      (let ((openclaw-gateway-token "tok")
            (openclaw-auto-reconnect nil))
        (openclaw-connect "ws://127.0.0.1:18789")
        (oc-mock--complete-handshake)
        (let ((buf (get-buffer-create "*mid-stream-dc*")))
          (with-current-buffer buf
            (openclaw-chat-mode)
            (setq-local openclaw--current-session "dc-sess")
            (openclaw--insert-input-area ""))
          ;; Start streaming
          (oc-mock--simulate-message
           (json-encode `((type . "event")
                          (event . "chat")
                          (payload . ((sessionKey . "dc-sess")
                                      (state . "delta")
                                      (delta . "partial response"))))))
          ;; Verify mid-stream state
          (with-current-buffer buf
            (oc-test-assert-equal 'thinking openclaw--run-state
                                  "State is thinking during stream")
            (oc-test-assert-nonnil openclaw--streaming-marker
                                   "Streaming marker set during stream"))
          ;; Simulate connection drop
          (openclaw--on-close nil)
          ;; Verify state reset
          (with-current-buffer buf
            (oc-test-assert-equal 'idle openclaw--run-state
                                  "State reset to idle after disconnect")
            (oc-test-assert-nil openclaw--streaming-marker
                                "Streaming marker cleared after disconnect")
            (oc-test-assert-equal "" openclaw--streaming-text
                                  "Streaming text cleared after disconnect")
            (oc-test-assert-match "interrupted" (buffer-string)
                                  "Interrupted notice shown in buffer"))
          (kill-buffer buf)))
    (openclaw--cancel-reconnect)
    (oc-mock--uninstall)))

(oc-test-deftest spec-12.2-reconnect-resets-stale-streaming
  "SPEC-12.2: Reconnect after mid-stream drop resets streaming state."
  (oc-mock--install)
  (unwind-protect
      (let ((openclaw-gateway-token "tok")
            (openclaw-auto-reconnect nil))
        (openclaw-connect "ws://127.0.0.1:18789")
        (oc-mock--complete-handshake)
        (let ((buf (get-buffer-create "*reconnect-stream*")))
          (with-current-buffer buf
            (openclaw-chat-mode)
            (setq-local openclaw--current-session "rc-sess")
            (openclaw--insert-input-area ""))
          ;; Start streaming
          (oc-mock--simulate-message
           (json-encode `((type . "event")
                          (event . "chat")
                          (payload . ((sessionKey . "rc-sess")
                                      (state . "delta")
                                      (delta . "in progress"))))))
          ;; Reconnect (on-open resets streaming state)
          (openclaw-connect "ws://127.0.0.1:18789")
          (with-current-buffer buf
            (oc-test-assert-equal 'idle openclaw--run-state
                                  "State is idle after reconnect")
            (oc-test-assert-nil openclaw--streaming-marker
                                "Streaming marker nil after reconnect")
            (oc-test-assert-equal "" openclaw--streaming-text
                                  "Streaming text empty after reconnect"))
          (kill-buffer buf)))
    (openclaw--cancel-reconnect)
    (oc-mock--uninstall)))

(oc-test-deftest spec-12.3-clean-buffer-unaffected-by-reset
  "SPEC-12.3: Buffers not streaming are unaffected by streaming reset."
  (oc-mock--install)
  (unwind-protect
      (let ((openclaw-gateway-token "tok")
            (openclaw-auto-reconnect nil))
        (openclaw-connect "ws://127.0.0.1:18789")
        (oc-mock--complete-handshake)
        (let ((buf (get-buffer-create "*clean-buf*")))
          (with-current-buffer buf
            (openclaw-chat-mode)
            (setq-local openclaw--current-session "clean-sess")
            (openclaw--insert-input-area "")
            (let ((content-before (buffer-string)))
              ;; Trigger reset
              (openclaw--reset-all-streaming-state)
              (oc-test-assert-equal content-before (buffer-string)
                                    "Clean buffer content unchanged after reset")
              (oc-test-assert-equal 'idle openclaw--run-state
                                    "Clean buffer stays idle")))
          (kill-buffer buf)))
    (oc-mock--uninstall)))

(oc-test-deftest spec-12.4-send-after-interrupted-stream
  "SPEC-12.4: Can send new message after stream was interrupted by disconnect."
  (oc-mock--install)
  (unwind-protect
      (let ((openclaw-gateway-token "tok")
            (openclaw-auto-reconnect nil))
        (openclaw-connect "ws://127.0.0.1:18789")
        (oc-mock--complete-handshake)
        (let ((buf (get-buffer-create "*send-after-dc*")))
          (with-current-buffer buf
            (openclaw-chat-mode)
            (setq-local openclaw--current-session "send-dc-sess")
            (openclaw--insert-input-area ""))
          ;; Stream then disconnect
          (oc-mock--simulate-message
           (json-encode `((type . "event")
                          (event . "chat")
                          (payload . ((sessionKey . "send-dc-sess")
                                      (state . "delta")
                                      (delta . "partial"))))))
          (openclaw--on-close nil)
          ;; Reconnect
          (openclaw-connect "ws://127.0.0.1:18789")
          (oc-mock--complete-handshake)
          (setq oc-mock--sent-frames nil)
          ;; Send message
          (with-current-buffer buf
            (goto-char (point-max))
            (insert "retry message")
            (openclaw-send-message)
            (let* ((sent (oc-mock--last-sent-parsed))
                   (params (alist-get 'params sent)))
              (oc-test-assert-equal "chat.send" (alist-get 'method sent)
                                    "chat.send works after interrupted stream")
              (oc-test-assert-equal "retry message" (alist-get 'message params)
                                    "Message text correct after interrupted stream")))
          (kill-buffer buf)))
    (openclaw--cancel-reconnect)
    (oc-mock--uninstall)))

;;; ============================================================
;;; SPEC-13: Keepalive / Heartbeat Pings
;;; ============================================================

(oc-test-deftest spec-13.1-keepalive-customization-exists
  "SPEC-13.1: Keepalive customization variable exists and defaults to t."
  (oc-test-assert-nonnil (boundp 'openclaw-keepalive)
                         "openclaw-keepalive variable exists")
  (oc-test-assert-equal t (default-value 'openclaw-keepalive)
                        "openclaw-keepalive defaults to t"))

(oc-test-deftest spec-13.2-keepalive-extracts-tick-interval
  "SPEC-13.2: Handshake extracts tickIntervalMs for keepalive interval."
  (oc-mock--install)
  (unwind-protect
      (let ((openclaw-gateway-token "tok")
            (openclaw-keepalive t)
            (openclaw--keepalive-interval nil))
        (openclaw-connect "ws://127.0.0.1:18789")
        ;; Simulate challenge
        (oc-mock--simulate-message
         (json-encode `((type . "event")
                        (event . "connect.challenge")
                        (payload . ((nonce . "n1") (ts . 1000))))))
        ;; Find connect request and respond with tickIntervalMs
        (let* ((connect-frame (oc-mock--last-sent-parsed))
               (req-id (alist-get 'id connect-frame)))
          (oc-mock--simulate-message
           (json-encode `((type . "res")
                          (id . ,req-id)
                          (ok . t)
                          (payload . ((type . "hello-ok")
                                      (protocol . 3)
                                      (policy . ((tickIntervalMs . 15000)))))))))
        (oc-test-assert-equal 15.0 openclaw--keepalive-interval
                              "Keepalive interval extracted from tickIntervalMs"))
    (openclaw--cancel-keepalive)
    (openclaw--cancel-reconnect)
    (oc-mock--uninstall)))

(oc-test-deftest spec-13.3-keepalive-sends-ping
  "SPEC-13.3: Keepalive function sends a ping request."
  (oc-mock--install)
  (unwind-protect
      (let ((openclaw-gateway-token "tok"))
        (openclaw-connect "ws://127.0.0.1:18789")
        (oc-mock--complete-handshake)
        (setq oc-mock--sent-frames nil)
        (openclaw--send-keepalive)
        (let* ((sent (oc-mock--last-sent-parsed))
               (method (alist-get 'method sent)))
          (oc-test-assert-equal "ping" method
                                "Keepalive sends ping method")))
    (openclaw--cancel-keepalive)
    (openclaw--cancel-reconnect)
    (oc-mock--uninstall)))

(oc-test-deftest spec-13.4-keepalive-cancelled-on-close
  "SPEC-13.4: Keepalive timer cancelled on explicit close."
  (oc-mock--install)
  (unwind-protect
      (let ((openclaw-gateway-token "tok")
            (openclaw-keepalive t))
        (openclaw-connect "ws://127.0.0.1:18789")
        (oc-mock--complete-handshake)
        ;; Manually set keepalive to simulate it running
        (setq openclaw--keepalive-interval 15.0)
        (openclaw--start-keepalive)
        (oc-test-assert-nonnil openclaw--keepalive-timer
                               "Keepalive timer is running")
        (openclaw-close-connection)
        (oc-test-assert-nil openclaw--keepalive-timer
                            "Keepalive timer cancelled after close"))
    (openclaw--cancel-keepalive)
    (openclaw--cancel-reconnect)
    (oc-mock--uninstall)))

(oc-test-deftest spec-13.5-keepalive-disabled-when-off
  "SPEC-13.5: Keepalive does not start when openclaw-keepalive is nil."
  (oc-mock--install)
  (unwind-protect
      (let ((openclaw-gateway-token "tok")
            (openclaw-keepalive nil))
        (setq openclaw--keepalive-interval 15.0)
        (openclaw--start-keepalive)
        (oc-test-assert-nil openclaw--keepalive-timer
                            "Keepalive timer not started when disabled"))
    (openclaw--cancel-keepalive)
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
