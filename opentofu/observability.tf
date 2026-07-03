##############################################################################
# Prometheus + Grafana
#
# A minimal observability stack that scrapes the mq-prometheus service
# (port 9158 on the IBM MQ pod) and renders the dashboards that ship in
# this repository.
#
# Both Prometheus and Grafana use ClusterIP services. The README shows
# how to reach Grafana with `kubectl port-forward`.
##############################################################################

locals {
  prometheus_labels = {
    "app.kubernetes.io/name"     = "prometheus"
    "app.kubernetes.io/instance" = "prometheus"
  }
  grafana_labels = {
    "app.kubernetes.io/name"     = "grafana"
    "app.kubernetes.io/instance" = "grafana"
  }

  # UID baked into the dashboard JSON files. The Grafana datasource we
  # provision below uses the same UID so the dashboards resolve their
  # Prometheus datasource without any post-import editing.
  prometheus_datasource_uid = "I9N3CCHIz"

  # Value assigned to the `k8s_instance` label on metrics scraped from
  # the MQ exporter. The bundled dashboards filter every panel by
  # `k8s_instance="[[instance]]"` and discover allowed values via
  # `label_values(ibmmq_qmgr_status, k8s_instance)`.
  k8s_instance = "ibm-mq-${var.qmgr_name}"
}

##############################################################################
# Prometheus
##############################################################################

resource "kubernetes_config_map" "prometheus_config" {
  metadata {
    name      = "prometheus-config"
    namespace = kubernetes_namespace.mq.metadata[0].name
    labels    = local.prometheus_labels
  }
  data = {
    "prometheus.yml" = <<-YAML
      global:
        scrape_interval: 15s
        evaluation_interval: 15s

      scrape_configs:
        - job_name: ibm-mq
          metrics_path: /metrics
          static_configs:
            - targets:
                - ${kubernetes_service.mq_prometheus.metadata[0].name}.${kubernetes_namespace.mq.metadata[0].name}.svc.cluster.local:9158
              labels:
                k8s_instance: ${local.k8s_instance}
    YAML
  }
}

resource "kubernetes_deployment" "prometheus" {
  metadata {
    name      = "prometheus"
    namespace = kubernetes_namespace.mq.metadata[0].name
    labels    = local.prometheus_labels
  }

  spec {
    replicas = 1
    selector {
      match_labels = local.prometheus_labels
    }
    template {
      metadata {
        labels = local.prometheus_labels
        annotations = {
          # Force a rollout when the scrape config changes.
          "checksum/config" = sha256(kubernetes_config_map.prometheus_config.data["prometheus.yml"])
        }
      }
      spec {
        container {
          name  = "prometheus"
          image = "prom/prometheus:v2.54.1"
          args = [
            "--config.file=/etc/prometheus/prometheus.yml",
            "--storage.tsdb.path=/prometheus",
            "--storage.tsdb.retention.time=6h",
            "--web.listen-address=:9090",
          ]
          port {
            name           = "http"
            container_port = 9090
          }
          volume_mount {
            name       = "config"
            mount_path = "/etc/prometheus"
            read_only  = true
          }
          volume_mount {
            name       = "data"
            mount_path = "/prometheus"
          }
          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }
        }
        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.prometheus_config.metadata[0].name
          }
        }
        volume {
          name = "data"
          empty_dir {}
        }
      }
    }
  }
}

resource "kubernetes_service" "prometheus" {
  metadata {
    name      = "prometheus"
    namespace = kubernetes_namespace.mq.metadata[0].name
    labels    = local.prometheus_labels
  }
  spec {
    type     = "ClusterIP"
    selector = local.prometheus_labels
    port {
      name        = "http"
      port        = 9090
      target_port = 9090
    }
  }
}

##############################################################################
# Grafana
##############################################################################

resource "kubernetes_config_map" "grafana_datasource" {
  metadata {
    name      = "grafana-datasource"
    namespace = kubernetes_namespace.mq.metadata[0].name
    labels    = local.grafana_labels
  }
  data = {
    "datasource.yml" = <<-YAML
      apiVersion: 1
      datasources:
        - name: Prometheus
          # UID matches the value baked into the dashboard JSON.
          uid: ${local.prometheus_datasource_uid}
          type: prometheus
          access: proxy
          url: http://${kubernetes_service.prometheus.metadata[0].name}.${kubernetes_namespace.mq.metadata[0].name}.svc.cluster.local:9090
          isDefault: true
          editable: false
    YAML
  }
}

resource "kubernetes_config_map" "grafana_dashboard_provider" {
  metadata {
    name      = "grafana-dashboard-provider"
    namespace = kubernetes_namespace.mq.metadata[0].name
    labels    = local.grafana_labels
  }
  data = {
    "provider.yml" = <<-YAML
      apiVersion: 1
      providers:
        - name: ibm-mq
          orgId: 1
          folder: IBM MQ
          type: file
          disableDeletion: true
          editable: false
          options:
            path: /var/lib/grafana/dashboards
    YAML
  }
}

resource "kubernetes_config_map" "grafana_dashboards" {
  metadata {
    name      = "grafana-dashboards"
    namespace = kubernetes_namespace.mq.metadata[0].name
    labels    = local.grafana_labels
  }
  data = {
    "queue-status.json"         = file("${path.module}/dashboards/queue-status.json")
    "channel-status.json"       = file("${path.module}/dashboards/channel-status.json")
    "queue-manager-status.json" = file("${path.module}/dashboards/queue-manager-status.json")
  }
}

resource "kubernetes_deployment" "grafana" {
  metadata {
    name      = "grafana"
    namespace = kubernetes_namespace.mq.metadata[0].name
    labels    = local.grafana_labels
  }

  spec {
    replicas = 1
    selector {
      match_labels = local.grafana_labels
    }
    template {
      metadata {
        labels = local.grafana_labels
        annotations = {
          "checksum/datasource" = sha256(kubernetes_config_map.grafana_datasource.data["datasource.yml"])
          "checksum/dashboards" = sha256(jsonencode(kubernetes_config_map.grafana_dashboards.data))
        }
      }
      spec {
        security_context {
          fs_group    = 472
          run_as_user = 472
        }

        container {
          name  = "grafana"
          image = "grafana/grafana:11.2.0"
          port {
            name           = "http"
            container_port = 3000
          }
          env {
            name  = "GF_SECURITY_ADMIN_USER"
            value = "admin"
          }
          env {
            name  = "GF_SECURITY_ADMIN_PASSWORD"
            value = "admin"
          }
          env {
            name  = "GF_AUTH_ANONYMOUS_ENABLED"
            value = "false"
          }
          env {
            name  = "GF_INSTALL_PLUGINS"
            value = ""
          }
          volume_mount {
            name       = "datasource"
            mount_path = "/etc/grafana/provisioning/datasources"
            read_only  = true
          }
          volume_mount {
            name       = "dashboard-provider"
            mount_path = "/etc/grafana/provisioning/dashboards"
            read_only  = true
          }
          volume_mount {
            name       = "dashboards"
            mount_path = "/var/lib/grafana/dashboards"
            read_only  = true
          }
          volume_mount {
            name       = "storage"
            mount_path = "/var/lib/grafana"
          }
          readiness_probe {
            http_get {
              path = "/api/health"
              port = 3000
            }
            initial_delay_seconds = 10
            period_seconds        = 5
          }
          resources {
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }
        }

        volume {
          name = "datasource"
          config_map {
            name = kubernetes_config_map.grafana_datasource.metadata[0].name
          }
        }
        volume {
          name = "dashboard-provider"
          config_map {
            name = kubernetes_config_map.grafana_dashboard_provider.metadata[0].name
          }
        }
        volume {
          name = "dashboards"
          config_map {
            name = kubernetes_config_map.grafana_dashboards.metadata[0].name
          }
        }
        volume {
          name = "storage"
          empty_dir {}
        }
      }
    }
  }
}

resource "kubernetes_service" "grafana" {
  metadata {
    name      = "grafana"
    namespace = kubernetes_namespace.mq.metadata[0].name
    labels    = local.grafana_labels
  }
  spec {
    type     = "ClusterIP"
    selector = local.grafana_labels
    port {
      name        = "http"
      port        = 3000
      target_port = 3000
    }
  }
}
