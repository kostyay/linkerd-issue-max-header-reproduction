FROM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /grpc-repro .

FROM alpine:3.22
COPY --from=build /grpc-repro /usr/local/bin/grpc-repro
ENTRYPOINT ["/usr/local/bin/grpc-repro"]
