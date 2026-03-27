IMAGE := corvo-zig:latest

.PHONY: build image logs

build:
	zig build -Drelease

image:
	docker build -t $(IMAGE) .

logs:
	kubectl logs -n corvo -l app=corvo --tail=30 -f
