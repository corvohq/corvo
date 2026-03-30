IMAGE := corvo-zig:latest

.PHONY: build css dev test image logs clean

css:
	tailwindcss -c ui/tailwind.config.js -i ui/input.css -o ui/tailwind.css --minify
	gzip -9 -k -f ui/tailwind.css

build: css
	zig build -Drelease

dev: css
	zig build -Drelease
	./zig-out/bin/corvo

test:
	zig build test

image:
	docker build -t $(IMAGE) .

logs:
	kubectl logs -n corvo -l app=corvo --tail=30 -f

clean:
	rm -rf zig-out .zig-cache
