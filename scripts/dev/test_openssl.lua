-- OpenSSL regression suite for LUAN runtime (lua-openssl 0.11.x + OpenSSL 3.0).
-- Runs 9 suites: hex/base64/random/digest/hmac/cipher/pkey/bn/x509.
-- Deployed on the 8081 test instance as handle/openssl_test.lua under site
-- "openssltest" (GET /openssltest/openssl_test) — keep in sync with that copy.
local json = require "json"

local function run_suite()
  local o = require("openssl")
  local results = {}
  local function t(name, fn)
    local ok, res = pcall(fn)
    table.insert(results, {suite = name, ok = (ok and true or false), detail = (ok and "PASS" or tostring(res))})
  end

  local function matches_hex(s, vec)
    if not s then return false end
    if s == vec then return true end
    if o.hex and o.hex(s) == vec then return true end
    return false
  end

  t("hex", function()
    local h = o.hex("hello")
    assert(h == "68656c6c6f", "encode: " .. tostring(h))
    assert(o.hex(h, false) == "hello", "decode")
    assert(o.hex("") == "")
  end)

  t("base64", function()
    local b = o.base64("hello world")
    assert(b == "aGVsbG8gd29ybGQ=", "enc: " .. tostring(b))
    assert(o.base64(b, false) == "hello world")
    assert(o.base64("a") == "YQ==")
  end)

  t("random", function()
    local r = o.random(16)
    assert(type(r) == "string" and #r == 16, "len=" .. tostring(#r))
    local r2 = o.random(16)
    assert(r ~= r2, "two draws identical")
  end)

  t("digest", function()
    local d = o.digest.digest("sha256", "abc")
    assert(matches_hex(d, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"), "sha256(abc)")
    local m = o.digest.digest("md5", "abc")
    assert(matches_hex(m, "900150983cd24fb0d6963f7d28e17f72"), "md5(abc)")
    local ctx = o.digest.new("sha1")
    ctx:update("a") ctx:update("b") ctx:update("c")
    local fin = ctx:final()
    assert(matches_hex(fin, "a9993e364706816aba3e25717850c26c9cd0d89d"), "sha1 incremental")
  end)

  t("hmac", function()
    local key = string.rep(string.char(0x0b), 20)
    local h
    if o.hmac.hmac then
      h = o.hmac.hmac("sha256", "Hi There", key)
    elseif o.hmac.digest then
      h = o.hmac.digest("sha256", "Hi There", key)
    else
      error("no hmac entry point")
    end
    assert(matches_hex(h, "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"), "RFC4231-1")
  end)

  t("cipher", function()
    local key = string.rep("k", 16)
    local iv = string.rep("i", 16)
    local plain = "attack at dawn 1234567890"
    local enc = o.cipher.encrypt("aes-128-cbc", plain, key, iv)
    assert(enc and #enc > 0, "encrypt")
    local dec = o.cipher.decrypt("aes-128-cbc", enc, key, iv)
    assert(dec == plain, "cbc roundtrip")
    local e2 = o.cipher.encrypt("aes-128-ecb", plain, key)
    local d2 = o.cipher.decrypt("aes-128-ecb", e2, key)
    assert(d2 == plain, "ecb roundtrip")
  end)

  t("pkey", function()
    local pk = o.pkey.new("RSA", 1024)
    if not pk then
      local ok2, p2 = pcall(function() return o.pkey.new{type = "RSA", bits = 1024} end)
      assert(ok2 and p2, "pkey.new variants failed")
      pk = p2
    end
    local pem = pk:export() or pk:tostring("PEM")
    assert(pem and pem:find("PRIVATE KEY"), "pem export")
    local data = "signed message"
    local sig
    local ok1, s1 = pcall(function() return pk:sign(data, "sha256") end)
    if ok1 and s1 then sig = s1 else
      local ok2, s2 = pcall(function() return pk:sign("sha256", data) end)
      assert(ok2, "sign failed")
      sig = s2
    end
    assert(sig and #sig > 0, "no sig")
    local pub = pk:get_public()
    assert(pub, "get_public")
    local okv, v = pcall(function() return pub:verify(data, sig, "sha256") end)
    if not okv then okv, v = pcall(function() return pub:verify(sig, data, "sha256") end) end
    assert(okv and v, "verify failed")
    local okr, pk2 = pcall(function() return o.pkey.read(pem, true) end)
    assert(okr and pk2, "pem import via pkey.read(pem,true)")
    local ok3, s3 = pcall(function() return pk2:sign(data, "sha256") end)
    assert(ok3 and s3, "reimported sign")
  end)

  t("bn", function()
    local new = o.bn.number or o.bn.new
    assert(new, "bn constructor")
    local a = new("12345678901234567890")
    local b = new("9876543210")
    assert(tostring(a + b) == "12345678911111111100", tostring(a + b))
    assert(tostring(a - b) == "12345678891358024680", tostring(a - b))
    assert(tostring(-a) == "-12345678901234567890", tostring(-a))
    assert(tostring(new("2") ^ new("10")) == "1024", tostring(new("2") ^ new("10")))
  end)

  t("x509", function()
    local pk = o.pkey.new("RSA", 1024)
    assert(pk, "pkey")
    local nm = o.x509.name.new{{commonName = "luan test"}}
    assert(nm, "name.new")
    local req = o.x509.req.new(nm, pk)   -- CSR: subject + pubkey
    assert(req, "x509.req.new")
    local cert = o.x509.new(1, req)      -- cert copies subject+pubkey from CSR
    assert(cert, "x509.new(serial, csr)")
    cert:notbefore(os.time() - 3600)
    cert:notafter(os.time() + 86400)
    local oks, se = pcall(function() return cert:sign(pk, cert) end)  -- self-sign
    assert(oks, "cert sign: " .. tostring(se))
    local pem = cert:export()
    assert(pem and pem:find("BEGIN CERTIFICATE"), "pem export")
    local parsed = o.x509.read(pem)
    assert(parsed, "read")
    local okv, v = pcall(function() return parsed:verify(pk) end)
    assert(okv and v, "cert verify")
    local okc, ce = pcall(function() return cert:check(pk) end)
    assert(okc, "cert check: " .. tostring(ce))
  end)

  local info = json.object()
  local v1, v2, v3 = o.version()
  info.lua_openssl = tostring(v1)
  info.lua = tostring(v2)
  info.openssl = tostring(v3)
  local n1, n2, n3 = o.version(true)
  info.openssl_num = tostring(n3)
  local okp, prov = pcall(function()
    if o.provider then
      local p = o.provider.load("default")
      return p and "provider.load(default) OK (OpenSSL 3.0 path)" or "provider.load returned nil"
    end
    return "no provider API exposed (sandbox module allowlist)"
  end)
  info.provider = (okp and tostring(prov) or tostring(prov))

  local passed = 0
  for _, r in ipairs(results) do if r.ok then passed = passed + 1 end end
  return { passed = passed, total = #results, version = info, suites = results }
end

local function onGet(req, resp)
  local result = run_suite()
  resp:addheader("Content-Type", "application/json; charset=utf-8")
  resp:reply(200, "OK", json.encode(result))
end

return { onGet = onGet }
