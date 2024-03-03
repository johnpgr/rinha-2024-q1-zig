FROM ubuntu

RUN apt-get update -y
RUN apt-get install -y curl xz-utils

WORKDIR /app
COPY ./zig-install.sh /app
RUN chmod +x /app/zig-install.sh
RUN /app/zig-install.sh
COPY /build.zig /app
COPY /build.zig.zon /app
COPY /src /app/src
RUN /opt/zig build --release=fast

ENTRYPOINT ["/app/zig-out/bin/rinha-2024-q1-ziglang"]
