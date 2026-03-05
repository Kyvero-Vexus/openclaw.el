# Makefile for openclaw.el

EMACS = emacs
BATCH = $(EMACS) --batch -Q

ELS = openclaw.el
ELCS = $(ELS:.el=.elc)

.PHONY: all compile test clean

all: compile

compile: $(ELCS)

%.elc: %.el
	$(BATCH) -f batch-byte-compile $<

test:
	$(BATCH) -L . -l openclaw.el \
		--eval "(message \"Tests: package loads correctly\")"

clean:
	rm -f $(ELCS)
