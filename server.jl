# Entrypoint shim. Prefer:
#   julia --project=. -e 'using Biscuit; Biscuit.serve()'
using Biscuit
Biscuit.serve(host="127.0.0.1", port=8080)
