FROM debian:bullseye-slim

#工作目录
WORKDIR /app

#安装需要的依赖
RUN apt update && apt install -y curl ca-certificates unzip wget

RUN curl -L https://raw.githubusercontent.com/nezhahq/scripts/main/agent/install.sh -o agent.sh && \
    chmod +x agent.sh
ENV NZ_SERVER=""
ENV NZ_TLS=true 
ENV NZ_CLIENT_SECRET=""
    
CMD ./agent.sh && tail -f /dev/null


