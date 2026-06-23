# Auth can also be supplied via env vars: XOA_URL, XOA_TOKEN, XOA_INSECURE.
# url must use the ws:// or wss:// scheme (it is a websocket endpoint).
provider "xenorchestra" {
  url      = var.xoa_url
  token    = var.xoa_token
  insecure = var.xoa_insecure
}
