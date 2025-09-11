FROM alpine:latest

#工作目录
WORKDIR /app

#安装需要的依赖
RUN apk add --no-cache curl ca-certificates unzip wget

RUN curl -L https://raw.githubusercontent.com/nezhahq/scripts/main/agent/install.sh -o agent.sh && \
    chmod +x agent.sh && \
ENV NZ_SERVER=nz.treeman.xx.kg:443 
ENV NZ_TLS=true 
ENV NZ_CLIENT_SECRET=sV7adnQ4xkgTN7NCpcOY0gxC33gLX20c 
    
ENTRYPOINT ['./agent.sh']
CMD ["-s", "${NEZHA_SERVER}:${NEZHA_PORT}", "-p", "${NEZHA_KEY}"]

