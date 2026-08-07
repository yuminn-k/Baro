FROM golang:1.24-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
COPY cmd ./cmd
COPY internal ./internal
RUN CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /out/workload ./cmd/workload \
    && CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /out/ingest ./cmd/ingest \
    && CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /out/consumer ./cmd/consumer

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/workload /workload
COPY --from=build /out/ingest /ingest
COPY --from=build /out/consumer /consumer
EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/workload"]
