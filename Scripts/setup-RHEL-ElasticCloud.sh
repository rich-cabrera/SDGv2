#!/bin/bash
#
# SDGv2 Setup Script for RHEL + Elastic Cloud (v9.2)
#
# This script configures an Elastic Cloud deployment with all necessary
# pipelines, templates, and enrichment data for:
#   - Windows Event logs (System, Application, Security)
#   - Proxy logs (ProxySG/Bluecoat)
#   - DNS logs
#   - Email/Malware logs
#   - NetFlow logs
#
# Compatible with: RHEL 8/9, CentOS Stream, Rocky Linux, Alma Linux
# Target: Elastic Cloud (ECH) v9.2
#

set -e

#############################################################################
# CONFIGURATION - UPDATE THESE VALUES FOR YOUR ENVIRONMENT
#############################################################################

# Elastic Cloud credentials and endpoints
# Find these in your Elastic Cloud deployment console
ELASTICSEARCH_URL="https://38b9249405d44e4fbe37122c0da005ed.us-east-1.aws.found.io:443"
KIBANA_URL="https://security-sandbox-4130d5.kb.us-east-1.aws.found.io"

# API Key authentication (base64 encoded)
API_KEY="S0RPczRwc0JYT1B0WGxRdENaV0U6c1o4aTVrMm1tTTV0SmZvUkF5ZXdoUQ=="

# Path to SDGv2 project (update if different)
SDG_HOME="/root/SDGv2"

# Elastic version
ELASTIC_VERSION="9.2"

#############################################################################
# DO NOT MODIFY BELOW THIS LINE (unless you know what you're doing)
#############################################################################

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Construct auth header for API Key authentication
AUTH_HEADER="Authorization: ApiKey ${API_KEY}"

# Helper functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_section() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN} $1${NC}"
    echo -e "${GREEN}========================================${NC}"
}

# Function to make Elasticsearch API calls with error handling
es_api() {
    local method=$1
    local endpoint=$2
    local data=$3
    local content_type=${4:-"application/json"}

    local response
    local http_code

    if [ -n "$data" ]; then
        if [ -f "$data" ]; then
            # Data is a file path
            response=$(curl -s -w "\n%{http_code}" -X "$method" \
                "${ELASTICSEARCH_URL}${endpoint}" \
                -H "Content-Type: ${content_type}" \
                -H "Accept: application/json" \
                -H "$AUTH_HEADER" \
                --data-binary @"$data" 2>&1)
        else
            # Data is inline JSON
            response=$(curl -s -w "\n%{http_code}" -X "$method" \
                "${ELASTICSEARCH_URL}${endpoint}" \
                -H "Content-Type: ${content_type}" \
                -H "Accept: application/json" \
                -H "$AUTH_HEADER" \
                -d "$data" 2>&1)
        fi
    else
        response=$(curl -s -w "\n%{http_code}" -X "$method" \
            "${ELASTICSEARCH_URL}${endpoint}" \
            -H "Content-Type: ${content_type}" \
            -H "Accept: application/json" \
            -H "$AUTH_HEADER" 2>&1)
    fi

    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
        return 0
    else
        log_warn "HTTP $http_code: $body"
        return 1
    fi
}

# Function to make Kibana API calls
kibana_api() {
    local method=$1
    local endpoint=$2
    local data=$3

    local response
    local http_code

    if [ -n "$data" ]; then
        if [ -f "$data" ]; then
            response=$(curl -s -w "\n%{http_code}" -X "$method" \
                "${KIBANA_URL}${endpoint}" \
                -H "Content-Type: application/json" \
                -H "kbn-xsrf: true" \
                -H "elastic-api-version: 2023-10-31" \
                -H "$AUTH_HEADER" \
                --data-binary @"$data" 2>&1)
        else
            response=$(curl -s -w "\n%{http_code}" -X "$method" \
                "${KIBANA_URL}${endpoint}" \
                -H "Content-Type: application/json" \
                -H "kbn-xsrf: true" \
                -H "elastic-api-version: 2023-10-31" \
                -H "$AUTH_HEADER" \
                -d "$data" 2>&1)
        fi
    else
        response=$(curl -s -w "\n%{http_code}" -X "$method" \
            "${KIBANA_URL}${endpoint}" \
            -H "Content-Type: application/json" \
            -H "kbn-xsrf: true" \
            -H "elastic-api-version: 2023-10-31" \
            -H "$AUTH_HEADER" 2>&1)
    fi

    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
        return 0
    else
        log_warn "HTTP $http_code: $body"
        return 1
    fi
}

#############################################################################
# PRE-FLIGHT CHECKS
#############################################################################

log_section "Pre-flight Checks"

# Check if running on RHEL-based system
if [ -f /etc/redhat-release ]; then
    log_info "Detected RHEL-based system: $(cat /etc/redhat-release)"
else
    log_warn "This script is designed for RHEL-based systems, but will attempt to continue..."
fi

# Check for required tools
for cmd in curl jq; do
    if ! command -v $cmd &> /dev/null; then
        log_error "$cmd is required but not installed."
        log_info "Install with: sudo dnf install -y $cmd"
        exit 1
    fi
done
log_success "Required tools (curl, jq) are available"

# Check if SDG_HOME exists
if [ ! -d "$SDG_HOME" ]; then
    log_error "SDG_HOME directory not found: $SDG_HOME"
    log_info "Please clone the SDGv2 repository or update the SDG_HOME variable"
    exit 1
fi
log_success "SDG_HOME found: $SDG_HOME"

# Test Elasticsearch connectivity and version
log_info "Testing Elasticsearch connectivity..."
ES_RESPONSE=$(curl -s -H "$AUTH_HEADER" "${ELASTICSEARCH_URL}/" 2>&1)
if echo "$ES_RESPONSE" | jq -e '.version.number' > /dev/null 2>&1; then
    ES_VERSION=$(echo "$ES_RESPONSE" | jq -r '.version.number')
    log_success "Connected to Elasticsearch ${ES_VERSION} at ${ELASTICSEARCH_URL}"
else
    log_error "Cannot connect to Elasticsearch. Please check your credentials and URL."
    exit 1
fi

# Test Kibana connectivity
log_info "Testing Kibana connectivity..."
if kibana_api "GET" "/api/status"; then
    log_success "Connected to Kibana at ${KIBANA_URL}"
else
    log_warn "Cannot connect to Kibana. Some features may not work."
fi

#############################################################################
# STEP 1: CREATE ENRICHMENT INDEX TEMPLATES
#############################################################################

log_section "Step 1: Creating Enrichment Index Templates"

declare -a ENRICH_TEMPLATES=(
    "enrich-windows.sysmon_operational"
    "enrich-rip"
    "enrich-bluecoat"
    "enrich-user_agents"
    "enrich-nginx"
)

for template in "${ENRICH_TEMPLATES[@]}"; do
    template_file="${SDG_HOME}/Index-Templates/Enrichment-Index-Templates/${template}.json"
    if [ -f "$template_file" ]; then
        log_info "Creating enrichment index template: $template"
        if es_api "PUT" "/_index_template/${template}" "$template_file"; then
            log_success "Created: $template"
        else
            log_warn "Failed to create: $template (may already exist)"
        fi
    else
        log_warn "Template file not found: $template_file"
    fi
done

#############################################################################
# STEP 2: LOAD ENRICHMENT DATA
#############################################################################

log_section "Step 2: Loading Enrichment Data"

declare -A ENRICH_DATA=(
    ["enrich-windows.sysmon_operational"]="enrich-windows.sysmon_operational.ndjson"
    ["enrich-rip"]="enrich-rip.ndjson"
    ["enrich-bluecoat"]="enrich-bluecoat.ndjson"
    ["enrich-user_agents"]="enrich-user_agents.ndjson"
    ["enrich-nginxv2"]="enrich-nginxv2.ndjson"
)

for index in "${!ENRICH_DATA[@]}"; do
    data_file="${SDG_HOME}/Enrichment-Data/${ENRICH_DATA[$index]}"
    if [ -f "$data_file" ]; then
        log_info "Loading enrichment data into: $index"
        if es_api "POST" "/${index}/_bulk?refresh=wait_for" "$data_file" "application/x-ndjson"; then
            log_success "Loaded data into: $index"
        else
            log_warn "Failed to load data into: $index"
        fi
    else
        log_warn "Data file not found: $data_file"
    fi
done

#############################################################################
# STEP 3: CREATE ENRICHMENT POLICIES
#############################################################################

log_section "Step 3: Creating Enrichment Policies"

declare -a ENRICH_POLICIES=(
    "enrich-windows.sysmon_operational"
    "remote-ips"
    "enrich-bluecoat"
    "user-agents"
    "enrich-nginx"
)

for policy in "${ENRICH_POLICIES[@]}"; do
    policy_file="${SDG_HOME}/Enrichment-Policies/${policy}.json"
    if [ -f "$policy_file" ]; then
        log_info "Creating enrichment policy: $policy"
        if es_api "PUT" "/_enrich/policy/${policy}" "$policy_file"; then
            log_success "Created: $policy"
        else
            log_warn "Failed to create: $policy (may already exist)"
        fi
    else
        log_warn "Policy file not found: $policy_file"
    fi
done

#############################################################################
# STEP 4: EXECUTE ENRICHMENT POLICIES
#############################################################################

log_section "Step 4: Executing Enrichment Policies"

for policy in "${ENRICH_POLICIES[@]}"; do
    log_info "Executing enrichment policy: $policy"
    if es_api "POST" "/_enrich/policy/${policy}/_execute" ""; then
        log_success "Executed: $policy"
    else
        log_warn "Failed to execute: $policy"
    fi
done

#############################################################################
# STEP 5: CREATE UTILITY INGEST PIPELINES
#############################################################################

log_section "Step 5: Creating Utility Ingest Pipelines"

declare -a UTILITY_PIPELINES=(
    "timestamp-cleanup"
    "logs-network_traffic-cleanup"
    "email-filter-rules"
    "nginx-cleanup"
    "date-math"
)

for pipeline in "${UTILITY_PIPELINES[@]}"; do
    pipeline_file="${SDG_HOME}/Ingest-Pipelines/${pipeline}.json"
    if [ -f "$pipeline_file" ]; then
        log_info "Creating utility pipeline: $pipeline"
        if es_api "PUT" "/_ingest/pipeline/${pipeline}" "$pipeline_file"; then
            log_success "Created: $pipeline"
        else
            log_warn "Failed to create: $pipeline"
        fi
    else
        log_warn "Pipeline file not found: $pipeline_file"
    fi
done

#############################################################################
# STEP 6: CREATE MAIN INGEST PIPELINES
#############################################################################

log_section "Step 6: Creating Main Ingest Pipelines"

declare -a MAIN_PIPELINES=(
    # Windows Sysmon
    "logs-windows.sysmon_operational"
    # Proxy
    "logs-proxysg.log"
    "enrich-bluecoat"
    # DNS
    "enrich-logs-network_traffic"
    "enrich-logs-network_traffic-dns"
    # Email/Malware
    "enrich-email"
    "logs-ti_abusech.malware@custom"
    # NetFlow
    "logs-netflow.log"
    # Nginx (bonus)
    "enrich-nginx"
)

for pipeline in "${MAIN_PIPELINES[@]}"; do
    pipeline_file="${SDG_HOME}/Ingest-Pipelines/${pipeline}.json"
    if [ -f "$pipeline_file" ]; then
        log_info "Creating main pipeline: $pipeline"
        if es_api "PUT" "/_ingest/pipeline/${pipeline}" "$pipeline_file"; then
            log_success "Created: $pipeline"
        else
            log_warn "Failed to create: $pipeline"
        fi
    else
        log_warn "Pipeline file not found: $pipeline_file"
    fi
done

#############################################################################
# STEP 7: CREATE CUSTOM INDEX TEMPLATES FOR WINDOWS EVENT LOGS
#############################################################################

log_section "Step 7: Creating Custom Windows Event Log Templates"

# Windows System Logs Template (wineventlog-system)
log_info "Creating index template: wineventlog-system"
es_api "PUT" "/_index_template/wineventlog-system" '{
  "index_patterns": ["wineventlog-system*"],
  "priority": 500,
  "template": {
    "settings": {
      "index": {
        "number_of_shards": 1,
        "number_of_replicas": 1,
        "default_pipeline": "logs-windows.sysmon_operational"
      }
    },
    "mappings": {
      "dynamic_templates": [
        {
          "winlog.event_data": {
            "path_match": "winlog.event_data.*",
            "mapping": { "type": "keyword" },
            "match_mapping_type": "string"
          }
        },
        {
          "winlog.user_data": {
            "path_match": "winlog.user_data.*",
            "mapping": { "type": "keyword" },
            "match_mapping_type": "string"
          }
        }
      ],
      "properties": {
        "@timestamp": { "type": "date" },
        "message": { "type": "text" },
        "host": {
          "properties": {
            "name": { "type": "keyword" },
            "hostname": { "type": "keyword" },
            "ip": { "type": "ip" },
            "os": {
              "properties": {
                "type": { "type": "keyword" },
                "name": { "type": "keyword" },
                "version": { "type": "keyword" }
              }
            }
          }
        },
        "event": {
          "properties": {
            "code": { "type": "keyword" },
            "action": { "type": "keyword" },
            "category": { "type": "keyword" },
            "dataset": { "type": "keyword" },
            "kind": { "type": "keyword" },
            "module": { "type": "keyword" },
            "outcome": { "type": "keyword" },
            "provider": { "type": "keyword" },
            "type": { "type": "keyword" },
            "ingested": { "type": "date" },
            "created": { "type": "date" }
          }
        },
        "winlog": {
          "properties": {
            "api": { "type": "keyword" },
            "channel": { "type": "keyword" },
            "computer_name": { "type": "keyword" },
            "event_id": { "type": "keyword" },
            "keywords": { "type": "keyword" },
            "opcode": { "type": "keyword" },
            "provider_guid": { "type": "keyword" },
            "provider_name": { "type": "keyword" },
            "record_id": { "type": "keyword" },
            "task": { "type": "keyword" },
            "version": { "type": "keyword" },
            "process": {
              "properties": {
                "pid": { "type": "long" },
                "thread": { "properties": { "id": { "type": "long" } } }
              }
            },
            "event_data": { "type": "object", "dynamic": true },
            "user_data": { "type": "object", "dynamic": true },
            "user": {
              "properties": {
                "name": { "type": "keyword" },
                "identifier": { "type": "keyword" },
                "domain": { "type": "keyword" },
                "type": { "type": "keyword" }
              }
            }
          }
        },
        "log": {
          "properties": {
            "level": { "type": "keyword" }
          }
        },
        "process": {
          "properties": {
            "name": { "type": "keyword" },
            "pid": { "type": "long" },
            "executable": { "type": "keyword" },
            "args": { "type": "keyword" },
            "command_line": { "type": "text", "fields": { "keyword": { "type": "keyword", "ignore_above": 2048 } } },
            "parent": {
              "properties": {
                "name": { "type": "keyword" },
                "pid": { "type": "long" },
                "executable": { "type": "keyword" }
              }
            },
            "pe": {
              "properties": {
                "original_file_name": { "type": "keyword" },
                "product": { "type": "keyword" },
                "company": { "type": "keyword" }
              }
            }
          }
        },
        "user": {
          "properties": {
            "name": { "type": "keyword" },
            "domain": { "type": "keyword" },
            "id": { "type": "keyword" }
          }
        },
        "source": {
          "properties": {
            "ip": { "type": "ip" },
            "port": { "type": "long" },
            "domain": { "type": "keyword" }
          }
        },
        "destination": {
          "properties": {
            "ip": { "type": "ip" },
            "port": { "type": "long" },
            "domain": { "type": "keyword" }
          }
        },
        "network": {
          "properties": {
            "protocol": { "type": "keyword" },
            "transport": { "type": "keyword" },
            "type": { "type": "keyword" },
            "direction": { "type": "keyword" }
          }
        },
        "file": {
          "properties": {
            "name": { "type": "keyword" },
            "path": { "type": "keyword" },
            "hash": {
              "properties": {
                "md5": { "type": "keyword" },
                "sha1": { "type": "keyword" },
                "sha256": { "type": "keyword" }
              }
            }
          }
        },
        "registry": {
          "properties": {
            "path": { "type": "keyword" },
            "key": { "type": "keyword" },
            "value": { "type": "keyword" },
            "data": {
              "properties": {
                "strings": { "type": "keyword" }
              }
            }
          }
        },
        "agent": {
          "properties": {
            "name": { "type": "keyword" },
            "type": { "type": "keyword" },
            "version": { "type": "keyword" },
            "id": { "type": "keyword" }
          }
        },
        "ecs": {
          "properties": {
            "version": { "type": "keyword" }
          }
        }
      }
    }
  }
}' && log_success "Created: wineventlog-system" || log_warn "Failed to create: wineventlog-system"

# Windows Application Logs Template (wineventlog-application)
log_info "Creating index template: wineventlog-application"
es_api "PUT" "/_index_template/wineventlog-application" '{
  "index_patterns": ["wineventlog-application*"],
  "priority": 500,
  "template": {
    "settings": {
      "index": {
        "number_of_shards": 1,
        "number_of_replicas": 1,
        "default_pipeline": "logs-windows.sysmon_operational"
      }
    },
    "mappings": {
      "dynamic_templates": [
        {
          "winlog.event_data": {
            "path_match": "winlog.event_data.*",
            "mapping": { "type": "keyword" },
            "match_mapping_type": "string"
          }
        },
        {
          "winlog.user_data": {
            "path_match": "winlog.user_data.*",
            "mapping": { "type": "keyword" },
            "match_mapping_type": "string"
          }
        }
      ],
      "properties": {
        "@timestamp": { "type": "date" },
        "message": { "type": "text" },
        "host": {
          "properties": {
            "name": { "type": "keyword" },
            "hostname": { "type": "keyword" },
            "ip": { "type": "ip" },
            "os": {
              "properties": {
                "type": { "type": "keyword" },
                "name": { "type": "keyword" },
                "version": { "type": "keyword" }
              }
            }
          }
        },
        "event": {
          "properties": {
            "code": { "type": "keyword" },
            "action": { "type": "keyword" },
            "category": { "type": "keyword" },
            "dataset": { "type": "keyword" },
            "kind": { "type": "keyword" },
            "module": { "type": "keyword" },
            "outcome": { "type": "keyword" },
            "provider": { "type": "keyword" },
            "type": { "type": "keyword" },
            "ingested": { "type": "date" },
            "created": { "type": "date" }
          }
        },
        "winlog": {
          "properties": {
            "api": { "type": "keyword" },
            "channel": { "type": "keyword" },
            "computer_name": { "type": "keyword" },
            "event_id": { "type": "keyword" },
            "keywords": { "type": "keyword" },
            "opcode": { "type": "keyword" },
            "provider_guid": { "type": "keyword" },
            "provider_name": { "type": "keyword" },
            "record_id": { "type": "keyword" },
            "task": { "type": "keyword" },
            "version": { "type": "keyword" },
            "process": {
              "properties": {
                "pid": { "type": "long" },
                "thread": { "properties": { "id": { "type": "long" } } }
              }
            },
            "event_data": { "type": "object", "dynamic": true },
            "user_data": { "type": "object", "dynamic": true },
            "user": {
              "properties": {
                "name": { "type": "keyword" },
                "identifier": { "type": "keyword" },
                "domain": { "type": "keyword" },
                "type": { "type": "keyword" }
              }
            }
          }
        },
        "log": {
          "properties": {
            "level": { "type": "keyword" }
          }
        },
        "process": {
          "properties": {
            "name": { "type": "keyword" },
            "pid": { "type": "long" },
            "executable": { "type": "keyword" },
            "args": { "type": "keyword" }
          }
        },
        "user": {
          "properties": {
            "name": { "type": "keyword" },
            "domain": { "type": "keyword" },
            "id": { "type": "keyword" }
          }
        },
        "error": {
          "properties": {
            "code": { "type": "keyword" },
            "message": { "type": "text" }
          }
        },
        "agent": {
          "properties": {
            "name": { "type": "keyword" },
            "type": { "type": "keyword" },
            "version": { "type": "keyword" },
            "id": { "type": "keyword" }
          }
        },
        "ecs": {
          "properties": {
            "version": { "type": "keyword" }
          }
        }
      }
    }
  }
}' && log_success "Created: wineventlog-application" || log_warn "Failed to create: wineventlog-application"

# Windows Security Logs Template (winlogsec)
log_info "Creating index template: winlogsec"
es_api "PUT" "/_index_template/winlogsec" '{
  "index_patterns": ["winlogsec*"],
  "priority": 500,
  "template": {
    "settings": {
      "index": {
        "number_of_shards": 1,
        "number_of_replicas": 1,
        "default_pipeline": "logs-windows.sysmon_operational"
      }
    },
    "mappings": {
      "dynamic_templates": [
        {
          "winlog.event_data": {
            "path_match": "winlog.event_data.*",
            "mapping": { "type": "keyword" },
            "match_mapping_type": "string"
          }
        },
        {
          "winlog.user_data": {
            "path_match": "winlog.user_data.*",
            "mapping": { "type": "keyword" },
            "match_mapping_type": "string"
          }
        }
      ],
      "properties": {
        "@timestamp": { "type": "date" },
        "message": { "type": "text" },
        "host": {
          "properties": {
            "name": { "type": "keyword" },
            "hostname": { "type": "keyword" },
            "ip": { "type": "ip" },
            "os": {
              "properties": {
                "type": { "type": "keyword" },
                "name": { "type": "keyword" },
                "version": { "type": "keyword" }
              }
            }
          }
        },
        "event": {
          "properties": {
            "code": { "type": "keyword" },
            "action": { "type": "keyword" },
            "category": { "type": "keyword" },
            "dataset": { "type": "keyword" },
            "kind": { "type": "keyword" },
            "module": { "type": "keyword" },
            "outcome": { "type": "keyword" },
            "provider": { "type": "keyword" },
            "type": { "type": "keyword" },
            "ingested": { "type": "date" },
            "created": { "type": "date" }
          }
        },
        "winlog": {
          "properties": {
            "api": { "type": "keyword" },
            "channel": { "type": "keyword" },
            "computer_name": { "type": "keyword" },
            "event_id": { "type": "keyword" },
            "keywords": { "type": "keyword" },
            "opcode": { "type": "keyword" },
            "provider_guid": { "type": "keyword" },
            "provider_name": { "type": "keyword" },
            "record_id": { "type": "keyword" },
            "task": { "type": "keyword" },
            "version": { "type": "keyword" },
            "logon": {
              "properties": {
                "id": { "type": "keyword" },
                "type": { "type": "keyword" },
                "failure": {
                  "properties": {
                    "reason": { "type": "keyword" },
                    "status": { "type": "keyword" },
                    "sub_status": { "type": "keyword" }
                  }
                }
              }
            },
            "process": {
              "properties": {
                "pid": { "type": "long" },
                "thread": { "properties": { "id": { "type": "long" } } }
              }
            },
            "event_data": { "type": "object", "dynamic": true },
            "user_data": { "type": "object", "dynamic": true },
            "user": {
              "properties": {
                "name": { "type": "keyword" },
                "identifier": { "type": "keyword" },
                "domain": { "type": "keyword" },
                "type": { "type": "keyword" }
              }
            }
          }
        },
        "log": {
          "properties": {
            "level": { "type": "keyword" }
          }
        },
        "process": {
          "properties": {
            "name": { "type": "keyword" },
            "pid": { "type": "long" },
            "executable": { "type": "keyword" },
            "args": { "type": "keyword" },
            "command_line": { "type": "text", "fields": { "keyword": { "type": "keyword", "ignore_above": 2048 } } }
          }
        },
        "user": {
          "properties": {
            "name": { "type": "keyword" },
            "domain": { "type": "keyword" },
            "id": { "type": "keyword" },
            "target": {
              "properties": {
                "name": { "type": "keyword" },
                "domain": { "type": "keyword" },
                "id": { "type": "keyword" }
              }
            }
          }
        },
        "source": {
          "properties": {
            "ip": { "type": "ip" },
            "port": { "type": "long" },
            "domain": { "type": "keyword" }
          }
        },
        "related": {
          "properties": {
            "user": { "type": "keyword" },
            "ip": { "type": "ip" },
            "hosts": { "type": "keyword" }
          }
        },
        "agent": {
          "properties": {
            "name": { "type": "keyword" },
            "type": { "type": "keyword" },
            "version": { "type": "keyword" },
            "id": { "type": "keyword" }
          }
        },
        "ecs": {
          "properties": {
            "version": { "type": "keyword" }
          }
        }
      }
    }
  }
}' && log_success "Created: winlogsec" || log_warn "Failed to create: winlogsec"

#############################################################################
# STEP 8: CREATE CUSTOM PROXY INDEX TEMPLATE
#############################################################################

log_section "Step 8: Creating Custom Proxy Index Template"

log_info "Creating index template: proxy"
es_api "PUT" "/_index_template/proxy" '{
  "index_patterns": ["proxy*"],
  "priority": 500,
  "template": {
    "settings": {
      "index": {
        "number_of_shards": 1,
        "number_of_replicas": 1,
        "default_pipeline": "logs-proxysg.log"
      }
    },
    "mappings": {
      "properties": {
        "@timestamp": { "type": "date" },
        "message": { "type": "text" },
        "host": {
          "properties": {
            "name": { "type": "keyword" },
            "ip": { "type": "ip" }
          }
        },
        "event": {
          "properties": {
            "action": { "type": "keyword" },
            "category": { "type": "keyword" },
            "dataset": { "type": "keyword" },
            "kind": { "type": "keyword" },
            "module": { "type": "keyword" },
            "outcome": { "type": "keyword" },
            "type": { "type": "keyword" },
            "ingested": { "type": "date" }
          }
        },
        "source": {
          "properties": {
            "ip": { "type": "ip" },
            "port": { "type": "long" },
            "address": { "type": "keyword" },
            "bytes": { "type": "long" },
            "geo": {
              "properties": {
                "city_name": { "type": "keyword" },
                "country_name": { "type": "keyword" },
                "country_iso_code": { "type": "keyword" },
                "location": { "type": "geo_point" }
              }
            }
          }
        },
        "destination": {
          "properties": {
            "ip": { "type": "ip" },
            "port": { "type": "long" },
            "address": { "type": "keyword" },
            "bytes": { "type": "long" },
            "domain": { "type": "keyword" },
            "geo": {
              "properties": {
                "city_name": { "type": "keyword" },
                "country_name": { "type": "keyword" },
                "country_iso_code": { "type": "keyword" },
                "location": { "type": "geo_point" }
              }
            }
          }
        },
        "url": {
          "properties": {
            "original": { "type": "keyword" },
            "full": { "type": "keyword" },
            "domain": { "type": "keyword" },
            "path": { "type": "keyword" },
            "query": { "type": "keyword" },
            "scheme": { "type": "keyword" },
            "port": { "type": "long" }
          }
        },
        "http": {
          "properties": {
            "request": {
              "properties": {
                "method": { "type": "keyword" },
                "bytes": { "type": "long" },
                "referrer": { "type": "keyword" }
              }
            },
            "response": {
              "properties": {
                "status_code": { "type": "long" },
                "bytes": { "type": "long" },
                "mime_type": { "type": "keyword" }
              }
            },
            "version": { "type": "keyword" }
          }
        },
        "user_agent": {
          "properties": {
            "original": { "type": "keyword" },
            "name": { "type": "keyword" },
            "version": { "type": "keyword" },
            "os": {
              "properties": {
                "full": { "type": "keyword" },
                "name": { "type": "keyword" },
                "version": { "type": "keyword" }
              }
            },
            "device": {
              "properties": {
                "name": { "type": "keyword" }
              }
            }
          }
        },
        "user": {
          "properties": {
            "name": { "type": "keyword" },
            "id": { "type": "keyword" },
            "domain": { "type": "keyword" }
          }
        },
        "proxy": {
          "properties": {
            "category": { "type": "keyword" },
            "code": { "type": "keyword" },
            "action": { "type": "keyword" }
          }
        },
        "network": {
          "properties": {
            "bytes": { "type": "long" },
            "protocol": { "type": "keyword" },
            "transport": { "type": "keyword" },
            "direction": { "type": "keyword" }
          }
        },
        "observer": {
          "properties": {
            "name": { "type": "keyword" },
            "type": { "type": "keyword" },
            "vendor": { "type": "keyword" },
            "product": { "type": "keyword" }
          }
        },
        "rule": {
          "properties": {
            "name": { "type": "keyword" },
            "id": { "type": "keyword" }
          }
        },
        "related": {
          "properties": {
            "ip": { "type": "ip" },
            "user": { "type": "keyword" },
            "hosts": { "type": "keyword" }
          }
        },
        "agent": {
          "properties": {
            "name": { "type": "keyword" },
            "type": { "type": "keyword" },
            "version": { "type": "keyword" },
            "id": { "type": "keyword" }
          }
        },
        "ecs": {
          "properties": {
            "version": { "type": "keyword" }
          }
        }
      }
    }
  }
}' && log_success "Created: proxy" || log_warn "Failed to create: proxy"

#############################################################################
# STEP 9: CREATE CUSTOM LINUX LOG INDEX TEMPLATES
#############################################################################

log_section "Step 9: Creating Custom Linux Log Templates"

# Linux varlog and cron logs Template (nixlog)
log_info "Creating index template: nixlog"
es_api "PUT" "/_index_template/nixlog" '{
  "index_patterns": ["nixlog*"],
  "priority": 500,
  "template": {
    "settings": {
      "index": {
        "number_of_shards": 1,
        "number_of_replicas": 1
      }
    },
    "mappings": {
      "properties": {
        "@timestamp": { "type": "date" },
        "message": { "type": "text", "fields": { "keyword": { "type": "keyword", "ignore_above": 2048 } } },
        "host": {
          "properties": {
            "name": { "type": "keyword" },
            "hostname": { "type": "keyword" },
            "ip": { "type": "ip" },
            "architecture": { "type": "keyword" },
            "os": {
              "properties": {
                "type": { "type": "keyword" },
                "name": { "type": "keyword" },
                "version": { "type": "keyword" },
                "kernel": { "type": "keyword" },
                "platform": { "type": "keyword" },
                "family": { "type": "keyword" }
              }
            }
          }
        },
        "event": {
          "properties": {
            "action": { "type": "keyword" },
            "category": { "type": "keyword" },
            "dataset": { "type": "keyword" },
            "kind": { "type": "keyword" },
            "module": { "type": "keyword" },
            "outcome": { "type": "keyword" },
            "provider": { "type": "keyword" },
            "type": { "type": "keyword" },
            "ingested": { "type": "date" },
            "created": { "type": "date" },
            "timezone": { "type": "keyword" }
          }
        },
        "log": {
          "properties": {
            "file": {
              "properties": {
                "path": { "type": "keyword" }
              }
            },
            "level": { "type": "keyword" },
            "logger": { "type": "keyword" },
            "origin": {
              "properties": {
                "file": {
                  "properties": {
                    "name": { "type": "keyword" }
                  }
                }
              }
            },
            "syslog": {
              "properties": {
                "facility": {
                  "properties": {
                    "code": { "type": "long" },
                    "name": { "type": "keyword" }
                  }
                },
                "priority": { "type": "long" },
                "severity": {
                  "properties": {
                    "code": { "type": "long" },
                    "name": { "type": "keyword" }
                  }
                }
              }
            }
          }
        },
        "process": {
          "properties": {
            "name": { "type": "keyword" },
            "pid": { "type": "long" },
            "executable": { "type": "keyword" },
            "args": { "type": "keyword" },
            "command_line": { "type": "text", "fields": { "keyword": { "type": "keyword", "ignore_above": 2048 } } },
            "working_directory": { "type": "keyword" }
          }
        },
        "user": {
          "properties": {
            "name": { "type": "keyword" },
            "id": { "type": "keyword" },
            "group": {
              "properties": {
                "name": { "type": "keyword" },
                "id": { "type": "keyword" }
              }
            }
          }
        },
        "source": {
          "properties": {
            "ip": { "type": "ip" },
            "port": { "type": "long" },
            "address": { "type": "keyword" }
          }
        },
        "destination": {
          "properties": {
            "ip": { "type": "ip" },
            "port": { "type": "long" },
            "address": { "type": "keyword" }
          }
        },
        "service": {
          "properties": {
            "name": { "type": "keyword" },
            "type": { "type": "keyword" }
          }
        },
        "systemd": {
          "properties": {
            "unit": { "type": "keyword" },
            "transport": { "type": "keyword" },
            "cgroup": { "type": "keyword" }
          }
        },
        "cron": {
          "properties": {
            "job": { "type": "keyword" },
            "schedule": { "type": "keyword" },
            "command": { "type": "text", "fields": { "keyword": { "type": "keyword", "ignore_above": 2048 } } }
          }
        },
        "related": {
          "properties": {
            "user": { "type": "keyword" },
            "ip": { "type": "ip" },
            "hosts": { "type": "keyword" }
          }
        },
        "tags": { "type": "keyword" },
        "labels": { "type": "object", "dynamic": true },
        "agent": {
          "properties": {
            "name": { "type": "keyword" },
            "type": { "type": "keyword" },
            "version": { "type": "keyword" },
            "id": { "type": "keyword" }
          }
        },
        "ecs": {
          "properties": {
            "version": { "type": "keyword" }
          }
        }
      }
    }
  }
}' && log_success "Created: nixlog" || log_warn "Failed to create: nixlog"

# Linux Security Logs Template (nixlogsec) - for audit and secure logs
log_info "Creating index template: nixlogsec"
es_api "PUT" "/_index_template/nixlogsec" '{
  "index_patterns": ["nixlogsec*"],
  "priority": 500,
  "template": {
    "settings": {
      "index": {
        "number_of_shards": 1,
        "number_of_replicas": 1
      }
    },
    "mappings": {
      "properties": {
        "@timestamp": { "type": "date" },
        "message": { "type": "text", "fields": { "keyword": { "type": "keyword", "ignore_above": 2048 } } },
        "host": {
          "properties": {
            "name": { "type": "keyword" },
            "hostname": { "type": "keyword" },
            "ip": { "type": "ip" },
            "architecture": { "type": "keyword" },
            "os": {
              "properties": {
                "type": { "type": "keyword" },
                "name": { "type": "keyword" },
                "version": { "type": "keyword" },
                "kernel": { "type": "keyword" },
                "platform": { "type": "keyword" },
                "family": { "type": "keyword" }
              }
            }
          }
        },
        "event": {
          "properties": {
            "action": { "type": "keyword" },
            "category": { "type": "keyword" },
            "dataset": { "type": "keyword" },
            "kind": { "type": "keyword" },
            "module": { "type": "keyword" },
            "outcome": { "type": "keyword" },
            "provider": { "type": "keyword" },
            "type": { "type": "keyword" },
            "ingested": { "type": "date" },
            "created": { "type": "date" },
            "sequence": { "type": "long" }
          }
        },
        "log": {
          "properties": {
            "file": {
              "properties": {
                "path": { "type": "keyword" }
              }
            },
            "level": { "type": "keyword" },
            "syslog": {
              "properties": {
                "facility": {
                  "properties": {
                    "code": { "type": "long" },
                    "name": { "type": "keyword" }
                  }
                },
                "priority": { "type": "long" },
                "severity": {
                  "properties": {
                    "code": { "type": "long" },
                    "name": { "type": "keyword" }
                  }
                }
              }
            }
          }
        },
        "process": {
          "properties": {
            "name": { "type": "keyword" },
            "pid": { "type": "long" },
            "ppid": { "type": "long" },
            "executable": { "type": "keyword" },
            "args": { "type": "keyword" },
            "command_line": { "type": "text", "fields": { "keyword": { "type": "keyword", "ignore_above": 2048 } } },
            "working_directory": { "type": "keyword" },
            "title": { "type": "keyword" }
          }
        },
        "user": {
          "properties": {
            "name": { "type": "keyword" },
            "id": { "type": "keyword" },
            "effective": {
              "properties": {
                "name": { "type": "keyword" },
                "id": { "type": "keyword" }
              }
            },
            "target": {
              "properties": {
                "name": { "type": "keyword" },
                "id": { "type": "keyword" }
              }
            },
            "group": {
              "properties": {
                "name": { "type": "keyword" },
                "id": { "type": "keyword" }
              }
            },
            "audit": {
              "properties": {
                "name": { "type": "keyword" },
                "id": { "type": "keyword" }
              }
            },
            "filesystem": {
              "properties": {
                "name": { "type": "keyword" },
                "id": { "type": "keyword" }
              }
            },
            "saved": {
              "properties": {
                "name": { "type": "keyword" },
                "id": { "type": "keyword" }
              }
            }
          }
        },
        "source": {
          "properties": {
            "ip": { "type": "ip" },
            "port": { "type": "long" },
            "address": { "type": "keyword" },
            "geo": {
              "properties": {
                "city_name": { "type": "keyword" },
                "country_name": { "type": "keyword" },
                "country_iso_code": { "type": "keyword" },
                "location": { "type": "geo_point" }
              }
            }
          }
        },
        "destination": {
          "properties": {
            "ip": { "type": "ip" },
            "port": { "type": "long" },
            "address": { "type": "keyword" }
          }
        },
        "auditd": {
          "properties": {
            "log": {
              "properties": {
                "sequence": { "type": "long" }
              }
            },
            "message_type": { "type": "keyword" },
            "result": { "type": "keyword" },
            "session": { "type": "keyword" },
            "summary": {
              "properties": {
                "actor": {
                  "properties": {
                    "primary": { "type": "keyword" },
                    "secondary": { "type": "keyword" }
                  }
                },
                "object": {
                  "properties": {
                    "type": { "type": "keyword" },
                    "primary": { "type": "keyword" },
                    "secondary": { "type": "keyword" }
                  }
                },
                "how": { "type": "keyword" }
              }
            },
            "data": {
              "type": "object",
              "dynamic": true
            },
            "paths": {
              "type": "nested",
              "properties": {
                "dev": { "type": "keyword" },
                "inode": { "type": "keyword" },
                "item": { "type": "keyword" },
                "mode": { "type": "keyword" },
                "name": { "type": "keyword" },
                "nametype": { "type": "keyword" },
                "ogid": { "type": "keyword" },
                "ouid": { "type": "keyword" },
                "rdev": { "type": "keyword" }
              }
            }
          }
        },
        "file": {
          "properties": {
            "path": { "type": "keyword" },
            "name": { "type": "keyword" },
            "directory": { "type": "keyword" },
            "inode": { "type": "keyword" },
            "mode": { "type": "keyword" },
            "uid": { "type": "keyword" },
            "gid": { "type": "keyword" },
            "owner": { "type": "keyword" },
            "group": { "type": "keyword" },
            "device": { "type": "keyword" },
            "type": { "type": "keyword" }
          }
        },
        "network": {
          "properties": {
            "direction": { "type": "keyword" },
            "type": { "type": "keyword" },
            "protocol": { "type": "keyword" },
            "transport": { "type": "keyword" }
          }
        },
        "service": {
          "properties": {
            "name": { "type": "keyword" },
            "type": { "type": "keyword" }
          }
        },
        "authentication": {
          "properties": {
            "method": { "type": "keyword" },
            "result": { "type": "keyword" },
            "type": { "type": "keyword" }
          }
        },
        "pam": {
          "properties": {
            "service": { "type": "keyword" },
            "session_state": { "type": "keyword" }
          }
        },
        "related": {
          "properties": {
            "user": { "type": "keyword" },
            "ip": { "type": "ip" },
            "hosts": { "type": "keyword" },
            "hash": { "type": "keyword" }
          }
        },
        "tags": { "type": "keyword" },
        "labels": { "type": "object", "dynamic": true },
        "agent": {
          "properties": {
            "name": { "type": "keyword" },
            "type": { "type": "keyword" },
            "version": { "type": "keyword" },
            "id": { "type": "keyword" }
          }
        },
        "ecs": {
          "properties": {
            "version": { "type": "keyword" }
          }
        }
      }
    }
  }
}' && log_success "Created: nixlogsec" || log_warn "Failed to create: nixlogsec"

#############################################################################
# STEP 10: CREATE CUSTOM FIREWALL INDEX TEMPLATE (Cisco ASA style)
#############################################################################

log_section "Step 10: Creating Custom Firewall Index Template"

# Cisco ASA-style Firewall Logs Template (firewall)
log_info "Creating index template: firewall"
es_api "PUT" "/_index_template/firewall" '{
  "index_patterns": ["firewall*"],
  "priority": 500,
  "template": {
    "settings": {
      "index": {
        "number_of_shards": 1,
        "number_of_replicas": 1
      }
    },
    "mappings": {
      "properties": {
        "@timestamp": { "type": "date" },
        "message": { "type": "text", "fields": { "keyword": { "type": "keyword", "ignore_above": 2048 } } },
        "host": {
          "properties": {
            "name": { "type": "keyword" },
            "hostname": { "type": "keyword" },
            "ip": { "type": "ip" }
          }
        },
        "event": {
          "properties": {
            "action": { "type": "keyword" },
            "category": { "type": "keyword" },
            "code": { "type": "keyword" },
            "dataset": { "type": "keyword" },
            "duration": { "type": "long" },
            "end": { "type": "date" },
            "kind": { "type": "keyword" },
            "module": { "type": "keyword" },
            "original": { "type": "keyword" },
            "outcome": { "type": "keyword" },
            "provider": { "type": "keyword" },
            "reason": { "type": "keyword" },
            "severity": { "type": "long" },
            "start": { "type": "date" },
            "timezone": { "type": "keyword" },
            "type": { "type": "keyword" },
            "ingested": { "type": "date" }
          }
        },
        "log": {
          "properties": {
            "level": { "type": "keyword" },
            "logger": { "type": "keyword" },
            "syslog": {
              "properties": {
                "facility": {
                  "properties": {
                    "code": { "type": "long" },
                    "name": { "type": "keyword" }
                  }
                },
                "priority": { "type": "long" },
                "severity": {
                  "properties": {
                    "code": { "type": "long" },
                    "name": { "type": "keyword" }
                  }
                }
              }
            }
          }
        },
        "source": {
          "properties": {
            "address": { "type": "keyword" },
            "ip": { "type": "ip" },
            "port": { "type": "long" },
            "bytes": { "type": "long" },
            "packets": { "type": "long" },
            "domain": { "type": "keyword" },
            "mac": { "type": "keyword" },
            "nat": {
              "properties": {
                "ip": { "type": "ip" },
                "port": { "type": "long" }
              }
            },
            "user": {
              "properties": {
                "name": { "type": "keyword" }
              }
            },
            "geo": {
              "properties": {
                "city_name": { "type": "keyword" },
                "continent_name": { "type": "keyword" },
                "country_iso_code": { "type": "keyword" },
                "country_name": { "type": "keyword" },
                "location": { "type": "geo_point" },
                "region_name": { "type": "keyword" }
              }
            },
            "as": {
              "properties": {
                "number": { "type": "long" },
                "organization": {
                  "properties": {
                    "name": { "type": "keyword" }
                  }
                }
              }
            }
          }
        },
        "destination": {
          "properties": {
            "address": { "type": "keyword" },
            "ip": { "type": "ip" },
            "port": { "type": "long" },
            "bytes": { "type": "long" },
            "packets": { "type": "long" },
            "domain": { "type": "keyword" },
            "mac": { "type": "keyword" },
            "nat": {
              "properties": {
                "ip": { "type": "ip" },
                "port": { "type": "long" }
              }
            },
            "user": {
              "properties": {
                "name": { "type": "keyword" }
              }
            },
            "geo": {
              "properties": {
                "city_name": { "type": "keyword" },
                "continent_name": { "type": "keyword" },
                "country_iso_code": { "type": "keyword" },
                "country_name": { "type": "keyword" },
                "location": { "type": "geo_point" },
                "region_name": { "type": "keyword" }
              }
            },
            "as": {
              "properties": {
                "number": { "type": "long" },
                "organization": {
                  "properties": {
                    "name": { "type": "keyword" }
                  }
                }
              }
            }
          }
        },
        "network": {
          "properties": {
            "application": { "type": "keyword" },
            "bytes": { "type": "long" },
            "community_id": { "type": "keyword" },
            "direction": { "type": "keyword" },
            "iana_number": { "type": "keyword" },
            "packets": { "type": "long" },
            "protocol": { "type": "keyword" },
            "transport": { "type": "keyword" },
            "type": { "type": "keyword" }
          }
        },
        "observer": {
          "properties": {
            "egress": {
              "properties": {
                "interface": {
                  "properties": {
                    "name": { "type": "keyword" }
                  }
                },
                "zone": { "type": "keyword" }
              }
            },
            "ingress": {
              "properties": {
                "interface": {
                  "properties": {
                    "name": { "type": "keyword" }
                  }
                },
                "zone": { "type": "keyword" }
              }
            },
            "hostname": { "type": "keyword" },
            "ip": { "type": "ip" },
            "name": { "type": "keyword" },
            "product": { "type": "keyword" },
            "serial_number": { "type": "keyword" },
            "type": { "type": "keyword" },
            "vendor": { "type": "keyword" },
            "version": { "type": "keyword" }
          }
        },
        "cisco": {
          "properties": {
            "asa": {
              "properties": {
                "message_id": { "type": "keyword" },
                "severity": { "type": "long" },
                "connection_id": { "type": "keyword" },
                "connection_type": { "type": "keyword" },
                "rule_name": { "type": "keyword" },
                "source_interface": { "type": "keyword" },
                "destination_interface": { "type": "keyword" },
                "icmp_type": { "type": "long" },
                "icmp_code": { "type": "long" },
                "mapped_source_ip": { "type": "ip" },
                "mapped_source_port": { "type": "long" },
                "mapped_destination_ip": { "type": "ip" },
                "mapped_destination_port": { "type": "long" },
                "threat_category": { "type": "keyword" },
                "threat_level": { "type": "keyword" },
                "tunnel_type": { "type": "keyword" },
                "command_line_arguments": { "type": "keyword" },
                "assigned_ip": { "type": "ip" },
                "privilege_level": { "type": "long" },
                "network_object": { "type": "keyword" },
                "termination_reason": { "type": "keyword" },
                "termination_initiator": { "type": "keyword" },
                "webvpn": {
                  "properties": {
                    "group_name": { "type": "keyword" }
                  }
                },
                "burst": {
                  "properties": {
                    "object": { "type": "keyword" },
                    "id": { "type": "keyword" },
                    "current_rate": { "type": "long" },
                    "current_burst": { "type": "long" },
                    "configured_rate": { "type": "long" },
                    "configured_burst": { "type": "long" },
                    "avg_rate": { "type": "long" }
                  }
                }
              }
            }
          }
        },
        "rule": {
          "properties": {
            "name": { "type": "keyword" },
            "id": { "type": "keyword" },
            "uuid": { "type": "keyword" },
            "category": { "type": "keyword" },
            "ruleset": { "type": "keyword" }
          }
        },
        "user": {
          "properties": {
            "name": { "type": "keyword" },
            "id": { "type": "keyword" },
            "domain": { "type": "keyword" },
            "group": {
              "properties": {
                "name": { "type": "keyword" },
                "id": { "type": "keyword" }
              }
            }
          }
        },
        "file": {
          "properties": {
            "name": { "type": "keyword" },
            "path": { "type": "keyword" },
            "size": { "type": "long" },
            "hash": {
              "properties": {
                "md5": { "type": "keyword" },
                "sha1": { "type": "keyword" },
                "sha256": { "type": "keyword" }
              }
            }
          }
        },
        "url": {
          "properties": {
            "original": { "type": "keyword" },
            "full": { "type": "keyword" },
            "domain": { "type": "keyword" },
            "path": { "type": "keyword" },
            "query": { "type": "keyword" },
            "scheme": { "type": "keyword" }
          }
        },
        "related": {
          "properties": {
            "ip": { "type": "ip" },
            "user": { "type": "keyword" },
            "hosts": { "type": "keyword" },
            "hash": { "type": "keyword" }
          }
        },
        "tags": { "type": "keyword" },
        "labels": { "type": "object", "dynamic": true },
        "agent": {
          "properties": {
            "name": { "type": "keyword" },
            "type": { "type": "keyword" },
            "version": { "type": "keyword" },
            "id": { "type": "keyword" }
          }
        },
        "ecs": {
          "properties": {
            "version": { "type": "keyword" }
          }
        }
      }
    }
  }
}' && log_success "Created: firewall" || log_warn "Failed to create: firewall"

#############################################################################
# STEP 11: CREATE REMAINING INDEX TEMPLATES (DNS, Email, NetFlow)
#############################################################################

log_section "Step 11: Creating Remaining Index Templates"

declare -a REMAINING_TEMPLATES=(
    "logs-network_traffic.dns"
    "logs-email.filter"
    "logs-ti_abusech.malware"
    "logs-netflow.log"
)

for template in "${REMAINING_TEMPLATES[@]}"; do
    template_file="${SDG_HOME}/Index-Templates/${template}.json"
    if [ -f "$template_file" ]; then
        log_info "Creating index template: $template"
        if es_api "PUT" "/_index_template/${template}" "$template_file"; then
            log_success "Created: $template"
        else
            log_warn "Failed to create: $template"
        fi
    else
        log_warn "Template file not found: $template_file"
    fi
done

#############################################################################
# STEP 12: CREATE COMPONENT TEMPLATES
#############################################################################

log_section "Step 12: Creating Component Templates"

declare -a COMPONENT_TEMPLATES=(
    "logs-windows.sysmon-operational"
    "logs-proxysg.log"
    "logs-network_traffic.dns"
    "logs-ti_abusech.malware"
    "logs-netflow.log"
)

for template in "${COMPONENT_TEMPLATES[@]}"; do
    template_file="${SDG_HOME}/Component-Templates/${template}.json"
    if [ -f "$template_file" ]; then
        log_info "Creating component template: $template"
        if es_api "PUT" "/_component_template/${template}" "$template_file"; then
            log_success "Created: $template"
        else
            log_warn "Failed to create: $template"
        fi
    else
        log_warn "Template file not found: $template_file"
    fi
done

#############################################################################
# STEP 13: CREATE INDICES
#############################################################################

log_section "Step 13: Creating Indices"

# Create Windows Event Log indices
declare -a WIN_INDICES=(
    "wineventlog-system"
    "wineventlog-application"
    "winlogsec"
)

for idx in "${WIN_INDICES[@]}"; do
    log_info "Creating index: $idx"
    if es_api "PUT" "/${idx}" '{}'; then
        log_success "Created: $idx"
    else
        log_warn "Failed to create: $idx (may already exist)"
    fi
done

# Create proxy index
log_info "Creating index: proxy"
if es_api "PUT" "/proxy" '{}'; then
    log_success "Created: proxy"
else
    log_warn "Failed to create: proxy (may already exist)"
fi

# Create Linux log indices
declare -a LINUX_INDICES=(
    "nixlog"
    "nixlogsec"
)

for idx in "${LINUX_INDICES[@]}"; do
    log_info "Creating index: $idx"
    if es_api "PUT" "/${idx}" '{}'; then
        log_success "Created: $idx"
    else
        log_warn "Failed to create: $idx (may already exist)"
    fi
done

# Create firewall index
log_info "Creating index: firewall"
if es_api "PUT" "/firewall" '{}'; then
    log_success "Created: firewall"
else
    log_warn "Failed to create: firewall (may already exist)"
fi

# Create data streams for the standard log types
declare -a DATA_STREAMS=(
    "logs-network_traffic.dns-default"
    "logs-email.filter-default"
    "logs-ti_abusech.malware-default"
    "logs-netflow.log-default"
)

for ds in "${DATA_STREAMS[@]}"; do
    log_info "Creating data stream: $ds"
    if es_api "PUT" "/_data_stream/${ds}" ""; then
        log_success "Created: $ds"
    else
        log_warn "Failed to create: $ds (may already exist)"
    fi
done

#############################################################################
# STEP 14: CREATE FLEET AGENT POLICIES (Optional)
#############################################################################

log_section "Step 14: Creating Fleet Agent Policies (Optional)"

# Infrastructure policy
infra_policy="${SDG_HOME}/Agent-Policies/Infra.json"
if [ -f "$infra_policy" ]; then
    log_info "Creating Infrastructure agent policy..."
    if kibana_api "POST" "/api/fleet/agent_policies?sys_monitoring=true" "$infra_policy"; then
        log_success "Created Infrastructure agent policy"
    else
        log_warn "Failed to create Infrastructure agent policy"
    fi
fi

# SecOps policy
secops_policy="${SDG_HOME}/Agent-Policies/SecOps.json"
if [ -f "$secops_policy" ]; then
    log_info "Creating SecOps agent policy..."
    if kibana_api "POST" "/api/fleet/agent_policies?sys_monitoring=true" "$secops_policy"; then
        log_success "Created SecOps agent policy"
    else
        log_warn "Failed to create SecOps agent policy"
    fi
fi

#############################################################################
# STEP 15: LOAD ENTITY ASSET CRITICALITY (Optional)
#############################################################################

log_section "Step 15: Loading Entity Asset Criticality (Optional)"

entity_file="${SDG_HOME}/Entity-Asset-List/entities-v1.json"
if [ -f "$entity_file" ]; then
    log_info "Loading entity asset criticality list..."
    if kibana_api "POST" "/api/asset_criticality/bulk" "$entity_file"; then
        log_success "Loaded entity asset criticality"
    else
        log_warn "Failed to load entity asset criticality"
    fi
fi

#############################################################################
# STEP 16: ENABLE PRERELEASE INTEGRATIONS (Optional)
#############################################################################

log_section "Step 16: Enabling Prerelease Integrations"

log_info "Enabling prerelease/beta integrations in Fleet..."
if kibana_api "PUT" "/api/fleet/settings" '{"prerelease_integrations_enabled": true}'; then
    log_success "Prerelease integrations enabled"
else
    log_warn "Failed to enable prerelease integrations"
fi

#############################################################################
# SUMMARY
#############################################################################

log_section "Setup Complete!"

echo ""
echo "The following indices/data streams are now configured:"
echo ""
echo "  WINDOWS EVENT LOGS (Custom Indices):"
echo "    [x] wineventlog-system       -> Windows System logs"
echo "    [x] wineventlog-application  -> Windows Application logs"
echo "    [x] winlogsec                -> Windows Security logs"
echo ""
echo "  LINUX LOGS (Custom Indices):"
echo "    [x] nixlog                   -> /var/log and cron logs"
echo "    [x] nixlogsec                -> audit and secure logs"
echo ""
echo "  FIREWALL LOGS (Custom Index):"
echo "    [x] firewall                 -> Cisco ASA-style firewall logs"
echo ""
echo "  PROXY LOGS (Custom Index):"
echo "    [x] proxy                    -> ProxySG/Bluecoat proxy logs"
echo ""
echo "  OTHER LOGS (Data Streams):"
echo "    [x] logs-network_traffic.dns-default    -> DNS logs"
echo "    [x] logs-email.filter-default           -> Email filter logs"
echo "    [x] logs-ti_abusech.malware-default     -> Malware/TI logs"
echo "    [x] logs-netflow.log-default            -> NetFlow logs"
echo ""
echo "  INGEST PIPELINES:"
echo "    - logs-windows.sysmon_operational (for Windows logs)"
echo "    - logs-proxysg.log (for Proxy logs)"
echo "    - enrich-logs-network_traffic-dns (for DNS)"
echo "    - enrich-email (for Email)"
echo "    - logs-ti_abusech.malware@custom (for Malware)"
echo "    - logs-netflow.log (for NetFlow)"
echo ""
echo "Next steps:"
echo "  1. Install Java:   sudo dnf install -y java-17-openjdk"
echo "  2. Install Gradle: sudo dnf install -y gradle"
echo "  3. Build SDGv2:    cd ${SDG_HOME} && gradle clean build fatJar"
echo "  4. Run generator:  java -jar ${SDG_HOME}/build/libs/SDGv2-1.0.0-SNAPSHOT.jar <track.yml>"
echo ""
echo "Available track files in ${SDG_HOME}/Tracks/:"
ls -1 "${SDG_HOME}/Tracks/"*.yml 2>/dev/null || echo "  (none found)"
echo ""
log_success "Setup script completed successfully!"
