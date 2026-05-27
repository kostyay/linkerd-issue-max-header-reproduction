package main

import (
	"context"
	"fmt"
	"log"
	"net"
	"os"
	"strconv"
	"strings"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/emptypb"
)

const (
	defaultAddress     = ":9090"
	defaultTarget      = "127.0.0.1:9090"
	methodName         = "/repro.Echo/EchoError"
	maxHeaderListBytes = 256 * 1024
)

type echoServer interface {
	EchoError(context.Context, *emptypb.Empty) (*emptypb.Empty, error)
}

type server struct {
	padBytes int
}

func main() {
	if len(os.Args) < 2 {
		log.Fatalf("usage: grpc-repro server|client")
	}

	switch os.Args[1] {
	case "server":
		runServer()
	case "client":
		runClient()
	default:
		log.Fatalf("unknown mode %q", os.Args[1])
	}
}

func runServer() {
	address := envString("ADDRESS", defaultAddress)
	listener, err := net.Listen("tcp", address)
	if err != nil {
		log.Fatalf("listen %s: %v", address, err)
	}

	grpcServer := grpc.NewServer(grpc.MaxHeaderListSize(maxHeaderListBytes))
	RegisterEchoServer(grpcServer, server{padBytes: envInt("PAD_TRAILER_BYTES", 22000)})
	log.Printf("serving gRPC on %s; trailer bytes=%d", address, envInt("PAD_TRAILER_BYTES", 22000))
	if err := grpcServer.Serve(listener); err != nil {
		log.Fatalf("serve: %v", err)
	}
}

func runClient() {
	target := envString("TARGET", defaultTarget)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	conn, err := grpc.NewClient(
		target,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithMaxHeaderListSize(maxHeaderListBytes),
	)
	if err != nil {
		log.Fatalf("new client: %v", err)
	}
	defer conn.Close()

	var trailer metadata.MD
	err = conn.Invoke(ctx, methodName, &emptypb.Empty{}, &emptypb.Empty{}, grpc.Trailer(&trailer))
	printResult(err, trailer)
}

func (s server) EchoError(ctx context.Context, _ *emptypb.Empty) (*emptypb.Empty, error) {
	message := fmt.Sprintf("test unauthenticated at %s", time.Now().UTC().Format(time.RFC3339Nano))
	grpc.SetTrailer(ctx, metadata.Pairs(
		"x-echo-message", message,
		"x-echo-pad", strings.Repeat("a", s.padBytes),
	))
	return nil, status.Error(codes.Unauthenticated, message)
}

func RegisterEchoServer(grpcServer *grpc.Server, implementation echoServer) {
	grpcServer.RegisterService(&grpc.ServiceDesc{
		ServiceName: "repro.Echo",
		HandlerType: (*echoServer)(nil),
		Methods: []grpc.MethodDesc{{
			MethodName: "EchoError",
			Handler:    echoErrorHandler,
		}},
	}, implementation)
}

func echoErrorHandler(
	implementation interface{},
	ctx context.Context,
	decode func(interface{}) error,
	interceptor grpc.UnaryServerInterceptor,
) (interface{}, error) {
	request := new(emptypb.Empty)
	if err := decode(request); err != nil {
		return nil, err
	}
	if interceptor == nil {
		return implementation.(echoServer).EchoError(ctx, request)
	}

	info := &grpc.UnaryServerInfo{Server: implementation, FullMethod: methodName}
	handler := func(ctx context.Context, request interface{}) (interface{}, error) {
		return implementation.(echoServer).EchoError(ctx, request.(*emptypb.Empty))
	}
	return interceptor(ctx, request, info, handler)
}

func printResult(err error, trailer metadata.MD) {
	grpcCode := codes.OK
	message := ""
	if err != nil {
		grpcCode = status.Code(err)
		message = status.Convert(err).Message()
	}

	fmt.Printf("grpc_code=%s\n", grpcCode)
	fmt.Printf("grpc_code_number=%d\n", grpcCode)
	fmt.Printf("grpc_message=%s\n", message)
	fmt.Printf("x_echo_message_count=%d\n", len(trailer.Get("x-echo-message")))
	fmt.Printf("x_echo_pad_value_bytes=%d\n", firstTrailerValueLen(trailer, "x-echo-pad"))
}

func firstTrailerValueLen(trailer metadata.MD, key string) int {
	values := trailer.Get(key)
	if len(values) == 0 {
		return 0
	}
	return len(values[0])
}

func envString(name string, fallback string) string {
	value := os.Getenv(name)
	if value == "" {
		return fallback
	}
	return value
}

func envInt(name string, fallback int) int {
	value := os.Getenv(name)
	if value == "" {
		return fallback
	}
	parsed, err := strconv.Atoi(value)
	if err != nil {
		log.Fatalf("invalid %s=%q: %v", name, value, err)
	}
	return parsed
}
