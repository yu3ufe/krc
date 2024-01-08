{% set krt_password = salt['pillar.get']('kartaca:user_password') %}

krt_group:
  group.present:
    - name: kartaca
    - gid: 2023

create_user:
  user.present:
    - name: kartaca
    - uid: 2023
    - gid: 2023
    - home: /home/krt
    - shell: /bin/bash
    - require:
      - group: kartaca

configure_pass:
  cmd.run:
    - name: echo 'kartaca:{{ krt_password }}' | sudo chpasswd
    - shell: /bin/bash
    - require:
      - user: kartaca

grant_sudo:
  file.managed:
    - name: /etc/sudoers.d/kartaca
    - contents: |
        kartaca ALL=(ALL) NOPASSWD:ALL
    - mode: '440'
    - require:
      - user: kartaca

enable_ip_forwarding:
  sysctl.present:
    - name: net.ipv4.ip_forward
    - value: 1

install_packages_general:
  pkg.installed:
    - pkgs:
      - htop
      - sysstat
      - mtr

{% if grains['os'] == 'Ubuntu' or grains['os_family'] == 'Debian' %}
set_timezone_deb:
  cmd.run:
    - name: timedatectl || sudo apt-get install systemd -y; sudo timedatectl set-timezone Europe/Istanbul

install_packages_deb:
  pkg.installed:
    - pkgs:
      - iputils-ping
      - dnsutils
      - tcptraceroute

add_hashicorp_repo_ubuntu:
  cmd.run:
    - name: sudo apt update && sudo apt install gpg && wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg && gpg --no-default-keyring --keyring /usr/share/keyrings/hashicorp-archive-keyring.gpg --fingerprint && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list && sudo apt update
    - unless: test -f /etc/apt/sources.list.d/hashicorp.list

install_terraform_ubuntu:
  cmd.run:
    - name: wget https://releases.hashicorp.com/terraform/1.6.4/terraform_1.6.4_linux_amd64.zip && sudo unzip terraform_1.6.4_linux_amd64.zip && sudo mv terraform /usr/local/bin/terraform

install_mysql:
  pkg.installed:
    - names:
      - mysql-server
      - python3-mysqldb

configure_mysql_service:
  service.running:
    - name: mysql
    - enable: True

create_mysql_database:
  mysql_database.present:
    - name: {{ salt['pillar.get']('kartaca:mysql:database_name') }}

create_mysql_user:
  mysql_user.present:
    - name: {{ salt['pillar.get']('kartaca:mysql:db_user') }}
    - host: localhost
    - password: {{ salt['pillar.get']('kartaca:mysql:db_password') }}

grant_mysql_privileges:
  mysql_grants.present:
    - grant: ALL PRIVILEGES
    - database: {{ salt['pillar.get']('kartaca:mysql:database_name') }}.*
    - user: {{ salt['pillar.get']('kartaca:mysql:db_user') }}
    - require:
      - mysql_user: create_mysql_user

create_mysql_backup_cron:
  cron.present:
    - name: "mysqldump {{ salt['pillar.get']('kartaca:mysql:database_name') }} > /backup/{{ salt['pillar.get']('kartaca:mysql:database_name') }}_`date +%Y-%m-%d`.sql"
    - user: root
    - minute: 0
    - hour: 2

{% elif grains['os'] == '*CentOS*' or grains['os_family'] == 'RedHat' %}
set_timezone_cen:
  cmd.run:
    - name: timedatectl || sudo yum install systemd -y; sudo timedatectl set-timezone Europe/Istanbul

install_packages_cent:
  pkg.installed:
    - pkgs:
      - iputils
      - bind-utils
      - traceroute

add_hashicorp_repo_centos:
  cmd.run:
    - name: wget -O- https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo | sudo tee /etc/yum.repos.d/hashicorp.repo
    - unless: test -f /etc/yum.repos.d/hashicorp.repo

install_terraform_centos:
  pkg.installed:
    - name: terraform
    - version: 1.6.4

setup_nginx:
  pkg.installed:
    - name: nginx

ngx_service:
  service.running:
    - name: nginx
    - enable: True

php_required:
  pkg.installed:
    - names:
      - php
      - php-fpm
      - php-mysqlnd
      - php-cli

wordpress_setup:
  cmd.run:
    - name: "cd /tmp && wget -O wordpress.tar.gz https://wordpress.org/latest.tar.gz"
    - creates: /tmp/wordpress.tar.gz

wordpress_config:
  cmd.run:
    - name: >
        cd /var/www &&
        mkdir -p wordpress2023 &&
        tar xzf /tmp/wordpress.tar.gz -C wordpress2023 --strip-components=1 &&
        sudo yum list installed policycoreutils-python-utils &>/dev/null || sudo yum install -y policycoreutils-python-utils; sudo semanage fcontext -a -t httpd_sys_content_t "/var/www/wordpress2023(/.*)?" &&
        restorecon -R /var/www/wordpress2023
    - creates: /var/www/wordpress2023
    - require:
      - cmd: wordpress_setup

ngx_refresh:
  cmd.run:
    - name: "systemctl reload nginx"
    - unless: "test `stat -c %Y /etc/nginx/nginx.conf` -le `stat -c %Y /var/cache/salt/minion/files/base/etc/nginx/nginx.conf`"

wp_conf_upd:
  cmd.run:
    - name: |
        sed -i "s/database_name_here/{{ salt['pillar.get']('kartaca:mysql:database_name', 'default_database') }}/g; s/username_here/{{ salt['pillar.get']('kartaca:mysql:db_user', 'default_user') }}/g; s/password_here/{{ salt['pillar.get']('kartaca:mysql:db_password', 'default_password') }}/g" /var/www/wordpress2023/wp-config-sample.php
    - require:
      - cmd: wordpress_config

wp_config:
  cmd.run:
    - name: cp /var/www/wordpress2023/wp-config-sample.php /var/www/wordpress2023/wp-config.php
    - require:
      - cmd: wp_conf_upd

wordpress_salt:
  cmd.run:
    - name: |
        curl -sS https://api.wordpress.org/secret-key/1.1/salt/ >> /var/www/wordpress2023/wp-config.php
    - require:
      - cmd: wp_config

ssl_cert:
  cmd.run:
    - name: |
        mkdir -p /etc/nginx/ssl
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout /etc/nginx/ssl/self-signed.key -out /etc/nginx/ssl/self-signed.crt -subj "/C=US/ST=State/L=City/O=Organization/CN=example.com"
        cat /etc/nginx/ssl/self-signed.key /etc/nginx/ssl/self-signed.crt > /etc/nginx/ssl/self-signed.pem
    - watch_in:
      - cmd: ngx_refresh

ngx_conf:
  file.managed:
    - name: /etc/nginx/nginx.conf
    - user: root
    - group: root
    - mode: 644
    - template: jinja
    - require:
      - pkg: nginx
    - watch_in:
      - cmd: ngx_refresh

ngx_month:
  cmd.run:
    - name: "echo '0 0 1 * * systemctl restart nginx' >> /etc/crontab"
    - require:
      - pkg: nginx

ngx_rotation:
  cmd.run:
    - name: "/usr/sbin/logrotate -f /etc/logrotate.d/nginx"
{% endif %}

{% set ip_block = '192.168.168.128/28' %}
{% set subnets = salt['cmd.run']('python3 -c "import ipaddress; print(list(ipaddress.IPv4Network(\'{}\')))"'.format(ip_block), python_shell=True) %}

{% for host_num in range(1, 16) %}
add_host_{{ host_num }}:
  cmd.run:
    - name: |
        if ! grep -q "{{ subnets.split(',')[host_num] }} kartaca.local" /etc/hosts; then
          echo "{{ subnets.split(',')[host_num] }} kartaca.local" | sudo tee -a /etc/hosts
        fi
{% endfor %}