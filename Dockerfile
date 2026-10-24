FROM golang:1.27.3

WORKDIR /app
ADD . /app
RUN go mod tidy

CMD ["sleep", "infinity"]
