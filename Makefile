.PHONY: build-iphone build-playcover test-unlocks

build-iphone:
	./scripts/build.sh iphone

build-playcover:
	./scripts/build.sh playcover

test-unlocks:
	./tests/test.sh
