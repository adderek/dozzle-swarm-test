# Build stage
FROM golang:1.21-alpine AS builder
WORKDIR /app
COPY go.mod .
#RUN go mod download  # If we had any dependencies, this would download them
COPY . .
RUN ls
RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o server .


FROM alpine:3.19
WORKDIR /app
COPY --from=builder /app/server .
COPY index.html .
CMD ["/app/server"]

