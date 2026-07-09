output "node_pool_names" {
  description = "Map of node pool names by pool key"
  value = {
    for k, v in google_container_node_pool.pools : k => v.name
  }
}

output "node_pool_self_links" {
  description = "Self links for node pools"
  value = {
    for k, v in google_container_node_pool.pools : k => v.self_link
  }
}
