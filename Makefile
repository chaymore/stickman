.PHONY: test build install open package verify clean

test:
	swift test

build:
	./scripts/build-app.sh

install:
	./stickman --install-app

open:
	./stickman --open-app

package:
	./scripts/package-release.sh

verify:
	./scripts/verify-portability.sh

clean:
	swift package clean
	rm -rf .local-build dist
