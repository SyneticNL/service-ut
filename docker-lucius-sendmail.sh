#!/usr/bin/env bash


init_sendmail_config() {
  DOMAINNAME=$(hostname)

  echo "test" >> /etc/hosts
}

sudo init_sendmail_config