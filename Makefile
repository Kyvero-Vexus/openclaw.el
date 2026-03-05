# Makefile for openclaw.el

EMACS = emacs
BATCH = $(EMACS) --batch

ELS = openclaw.el
ELCS = $(ELS:.el=.elc)

.PHONY: all compile test clean

all: compile

compile: $(ELCS)

%.elc: %.el
	$(BATCH) -Q --eval '(require (quote package))' --eval '(package-initialize)' \
		-L . -f batch-byte-compile $<

test:
	$(BATCH) -L . -L test \
		--eval '(require (quote package))' \
		--eval '(package-initialize)' \
		-l test-openclaw.el \
		-f oc-test-run-all

clean:
	rm -f $(ELCS)
