.PHONY: run build test swag fmt lint docker

run:
	go run .

build:
	go build -o bin/server .

test:
	go test ./...

swag:
	swag init -g main.go -o docs

fmt:
	gofmt -w .

lint:
	golangci-lint run ./... || true

docker:
	docker build -t family-finance-backend .
