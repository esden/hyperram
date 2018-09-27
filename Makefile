PROJ = hyperram
PIN_DEF = icebreaker.pcf
DEVICE = up5k

SRC = top.v hyper_xface.v baudgen.v baudgen_rx.v uart_rx.v uart_tx.v

all: $(PROJ).bin

%.blif: $(SRC)
	yosys -ql $*.log -p "synth_ice40 -top top -blif $@" $^ $(ADD_SRC)

%.json: $(SRC)
	yosys -ql $*.log -p 'synth_ice40 -top top -json $@' $^ $(ADD_SRC)

ifeq ($(USE_ARACHNEPNR),)
%.asc: $(PIN_DEF) %.json
	nextpnr-ice40 --$(DEVICE) --json $(filter-out $<,$^) --pcf $< --asc $@
else
%.asc: $(PIN_DEF) %.blif
	arachne-pnr -d $(subst up,,$(subst hx,,$(subst lp,,$(DEVICE)))) -o $@ -p $^
endif

%.bin: %.asc
	icepack $< $@

%.rpt: %.asc
	icetime -d $(DEVICE) -mtr $@ $<

prog: $(PROJ).bin
	iceprog $<

sudo-prog: $(PROJ).bin
	@echo 'Executing prog as root!!!'
	sudo iceprog $<

debug-serial:
	iverilog -o test serial_recv_tb.v uart_tx.v baudgen.v
	vvp test -fst
	gtkwave test.vcd gtk-serial.gtkw

debug-ram:
	iverilog -o test hyper_xface_tb.v hyper_xface.v
	vvp test -fst
	gtkwave test.vcd gtk.gtkw

clean:
	rm -f $(PROJ).blif $(PROJ).asc $(PROJ).rpt $(PROJ).bin $(PROJ).log $(PROJ).json

.SECONDARY:
.PHONY: all prog clean
