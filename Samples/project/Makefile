CC ?= clang
OUT := build/app

.PHONY: all clean
all: $(OUT)

$(OUT): src/main.c
	mkdir -p build
	$(CC) -O2 -o $@ $<

clean:
	rm -rf build
