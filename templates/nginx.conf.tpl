# ClashFeng — 管理后台 + API 同域名
upstream clashfeng_app {
    server 127.0.0.1:3001;
    keepalive 8;
}

server {
    listen 80;
    server_name {{DOMAIN}};

    client_max_body_size 10m;

    location / {
        proxy_pass http://clashfeng_app;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Connection "";
    }
}
