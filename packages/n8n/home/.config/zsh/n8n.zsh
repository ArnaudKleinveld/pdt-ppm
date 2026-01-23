# n8n service management helpers

alias n8n-up="cd $XDG_DATA_HOME/n8n && docker compose up -d && docker compose logs -f"
alias n8n-down="cd $XDG_DATA_HOME/n8n && docker compose down"
alias n8n-logs="docker compose -f $XDG_DATA_HOME/n8n/docker-compose.yml logs -f"
alias n8n-restart="n8n-down && n8n-up"
alias n8n-pull="cd $XDG_DATA_HOME/n8n && docker compose pull"
alias n8n-ps="docker compose -f $XDG_DATA_HOME/n8n/docker-compose.yml ps"

# Quick access to n8n directory
alias n8n-cd="cd $XDG_DATA_HOME/n8n"
