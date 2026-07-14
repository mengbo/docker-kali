FROM m.daocloud.io/docker.io/kalilinux/kali-rolling

ENV DEBIAN_FRONTEND=noninteractive

RUN sed -i 's|http://http.kali.org/kali|http://mirrors.tuna.tsinghua.edu.cn/kali|g' /etc/apt/sources.list.d/kali.sources

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates sudo git python3-pip postgresql-client \
        metasploit-framework \
        nmap gobuster dirb nikto sqlmap hydra john wpscan enum4linux wordlists \
    && rm -rf /var/lib/apt/lists/*

COPY scholar.crt /usr/local/share/ca-certificates/scholar.crt
RUN update-ca-certificates

COPY config/database.yml /usr/share/metasploit-framework/config/database.yml

RUN git clone https://github.com/Wh0am123/MCP-Kali-Server /opt/MCP-Kali-Server \
    && pip install --no-cache-dir --break-system-packages \
        -r /opt/MCP-Kali-Server/requirements.txt

EXPOSE 5000

CMD ["/bin/bash", "-c", "exec python3 /opt/MCP-Kali-Server/server.py --ip 0.0.0.0 --port 5000"]
