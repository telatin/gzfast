.PHONY: all clean

all:
	nimble build && nimble test

clean:
	rm -f ./gzfast
	find . -name '*.nim' -exec sh -c 'rm -f "$${0%.nim}"' {} \;
	find . -name '*.gz' -exec sh -c 'rm -f "$${0%.gz}"' {} \;