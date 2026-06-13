#!/usr/bin/env python3
"""
云签到脚本 — 纯 API 方式，可在 GitHub Actions / 服务器上运行
不依赖 fyiban 库，只用 requests + rsa，与你 Swift 版同一套 API 端点

用法:
  python3 cloud_checkin.py <手机号> <密码> [纬度] [经度] [学校] [校区] [act] [client_id]
  python3 cloud_checkin.py 13800138000 mypassword 24.571 118.617 福州大学 晋江

环境变量（GitHub Actions 用）:
  YIBAN_PHONE      手机号
  YIBAN_PASSWORD   密码
  YIBAN_LAT        纬度
  YIBAN_LNG        经度
  YIBAN_SCHOOL     学校
  YIBAN_CAMPUS     校区
  YIBAN_ACT        校本化 App 标识（默认 iapp7463=福州大学）
  YIBAN_CLIENT_ID  OAuth Client ID（默认 95626fa3080300ea）
  PUSH_KEY         Server酱 SendKey（可选）
"""

import sys
import os
import json
import time
import base64
import hashlib
import urllib.parse
import requests

# ============================================================
# RSA 加密（与 Swift 同公钥、同填充方式 PKCS1v1.5）
# ============================================================

RSA_PUBKEY = """-----BEGIN PUBLIC KEY-----
MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAzq0rgsM++ZxLRGHpdfre
Hu6UXhdlUS5P2WOxRG14qU8/iWSb/CkOqgOl8AGcOhlthkvolCdpUvVcVsVUxBv0
YRN0Jb64zPrn5aLVwQT4RJn5tXvoqLdHIXis7pljXAMDPVZOVlWJkDMk8YU6HDaA
MqsD6l5p9lg2LMP4OhMgaPX+CkO370LB5vRjJTHp03n+IqfxXoC7DEd+kxRIEM2C
EDgUSYDJBDgwBvGALZmvB/a1b0im9t1P/EmnuE7uN9NRFoWyVpOiEwo/Ti7rmJGf
qNT3vvtfWo4nXsm1rYQXsPayoKDSRaba3gFY/1SYWLAuSO2q2da5ZCcsAk5RKy0V
c1hUg8n6y0YLAvuzoXY5VyNMXkhH5Zc5Kg64b5RxILeZpZG0MV7GFY3sw//k7SNg
darKT8A0Iv3l3lfguX3HNi6dkf97kS/EiA0tbkIB/JNjv13mq8HL7LijRt2hkKqP
PhQW88xC/exZilU5pAavoZOPuZIOTUHqtpRq4ZeKl+wDf+e5lPYFDpihWGjplGpa
4BOSmGeo/SyVFPji9QF4Pk0DRJF/NjwJoAC60xHAVt5Z4gQSOOOjNZDCswA0ry2L
e8m5cv5vPGY75uVrGqALQ6Xm961PPc5cJ1q7tmEZMj+z5HE7tgAdhiPI6acKgrAv
+1k4N0OVqKamMS+PVpD05hUCAwEAAQ==
-----END PUBLIC KEY-----"""

def rsa_encrypt(text: str) -> str:
    """RSA PKCS1v1.5 加密 + base64（与 Swift SecKeyCreateEncryptedData 一致）"""
    try:
        from cryptography.hazmat.primitives import serialization, hashes
        from cryptography.hazmat.primitives.asymmetric import padding
        key = serialization.load_pem_public_key(RSA_PUBKEY.encode(), password=None)
        encrypted = key.encrypt(
            text.encode("utf-8"),
            padding.PKCS1v15()
        )
        return base64.b64encode(encrypted).decode()
    except ImportError:
        pass  # fall through to rsa library

    try:
        import rsa
        pubkey = rsa.PublicKey.load_pkcs1_openssl_pem(RSA_PUBKEY.encode())
        encrypted = rsa.encrypt(text.encode("utf-8"), pubkey)
        return base64.b64encode(encrypted).decode()
    except ImportError:
        pass

    # 最后的 fallback：用 hashlib 做纯 Python PKCS1（仅限小文本）
    raise RuntimeError("需要安装 cryptography 或 rsa 库: pip3 install cryptography")


# ============================================================
# API 流程
# ============================================================

UA = "Yiban"
APP_VERSION = "5.1.2"
# 以下从环境变量或参数获取（不同学校不同值）
# 默认值为福州大学

def log(msg):
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{ts}] {msg}")

def push_to_phone(title, body):
    key = os.environ.get("PUSH_KEY", "").strip()
    if not key:
        return
    try:
        requests.post(
            f"https://sctapi.ftqq.com/{key}.send",
            data={"title": title, "desp": body},
            timeout=5
        )
        log(f"📱 已推送到微信")
    except Exception as e:
        log(f"⚠️ 推送失败: {e}")


class YibanCloud:
    def __init__(self, phone, password, lat, lng, school, campus,
                 act="iapp7463", client_id="95626fa3080300ea"):
        self.phone = phone
        self.password = password
        self.lat = float(lat)
        self.lng = float(lng)
        self.school = school
        self.campus = campus
        self.act = act
        self.client_id = client_id
        self.redirect_uri = f"https://f.yiban.cn/{act}"
        self.access_token = ""
        self.session = requests.Session()
        self.session.headers.update({"User-Agent": UA, "AppVersion": APP_VERSION})
        # 预置 csrf_token
        for domain in ["api.uyiban.com", "c.uyiban.com", ".uyiban.com"]:
            self.session.cookies.set("csrf_token", "00000", domain=domain)

    def login(self) -> bool:
        """登录 + CAS OAuth"""
        if not self.phone or not self.password:
            log("❌ 未配置手机号或密码")
            return False

        encrypted = rsa_encrypt(self.password)

        # Step 1: 手机号登录
        for identify in ["1", "0"]:
            resp = self.session.post(
                "https://m.yiban.cn/api/v4/passport/login",
                data={
                    "ct": "2",
                    "identify": identify,
                    "mobile": self.phone,
                    "password": encrypted,
                }
            )
            data = resp.json()
            code = data.get("response")
            log(f"login identify={identify}: response={code}")

            if code != 100:
                # 永久性错误不重试
                if code in (200, 201, 202, 210):
                    log(f"❌ 登录被拒: {data.get('data', {}).get('message', code)}")
                    return False
                continue

            token = data.get("data", {}).get("access_token", "")
            if not token:
                continue
            self.access_token = token
            log("✅ API 登录成功")

            # Step 2: 获取 verify_request
            verify = self._get_verify_request()
            if not verify:
                log("⚠️ 无法获取 verify_request")
                continue
            log(f"verify_request: {verify[:16]}...")

            # Step 3: CAS OAuth
            if self._cas_auth(verify):
                return True

        log("❌ 登录失败")
        return False

    def _get_verify_request(self) -> str:
        headers = {
            "Authorization": f"Bearer {self.access_token}",
            "logintoken": self.access_token,
            "Origin": "https://c.uyiban.com",
            "User-Agent": UA,
            "AppVersion": APP_VERSION,
        }
        resp = requests.get(
            f"https://f.yiban.cn/iapp/index?act={self.act}",
            headers=headers,
            allow_redirects=False
        )
        log(f"f.yiban.cn/iapp/index: HTTP {resp.status_code}, body={resp.text[:200]}")
        location = resp.headers.get("Location", "")
        if "verify_request=" not in location:
            log(f"❌ 重定向地址中无 verify_request: {location[:80]}")
            return ""
        # 提取 verify_request 值
        params = urllib.parse.parse_qs(urllib.parse.urlparse(location).fragment)
        # Location 格式: https://c.uyiban.com/#/?verify_request=xxx...
        # parse_qs 对 fragment 不生效，手动提取
        before = location.split("verify_request=", 1)[-1]
        return before.split("&")[0]

    def _cas_auth(self, verify: str) -> bool:
        base_headers = {
            "Origin": "https://c.uyiban.com",
            "User-Agent": UA,
            "AppVersion": APP_VERSION,
        }

        # Step 3a: auth/yiban #1
        r1 = self.session.get(
            f"https://api.uyiban.com/base/c/auth/yiban?verifyRequest={verify}&CSRF=00000",
            headers=base_headers
        )
        log(f"auth/yiban #1: {r1.text[:120]}")

        # Step 3b: oauth code/html
        self.session.get(
            f"https://oauth.yiban.cn/code/html?client_id={self.client_id}&redirect_uri={self.redirect_uri}",
            headers=base_headers
        )
        log("oauth code/html 完成")

        # Step 3c: oauth usersure
        self.session.post(
            "https://oauth.yiban.cn/code/usersure",
            data={"client_id": self.client_id, "redirect_uri": self.redirect_uri},
            headers=base_headers
        )
        log("oauth usersure 完成")

        # Step 3d: auth/yiban #2
        r4 = self.session.get(
            f"https://api.uyiban.com/base/c/auth/yiban?verifyRequest={verify}&CSRF=00000",
            headers=base_headers
        )
        if r4.json().get("code") == 0:
            log("✅ CAS OAuth 认证完成")
            return True
        log(f"❌ auth/yiban #2 失败: {r4.text[:200]}")
        return False

    def do_checkin(self) -> bool:
        """执行晚点签到"""
        if not self.access_token:
            log("❌ 未登录")
            return False

        # 获取签到时段
        resp = self.session.get(
            "https://api.uyiban.com/nightAttendance/student/index/signPosition?CSRF=00000",
            headers={"Origin": "https://c.uyiban.com", "User-Agent": UA, "AppVersion": APP_VERSION}
        )
        data = resp.json()
        log(f"签到时段: {json.dumps(data, ensure_ascii=False)[:150]}")

        if data.get("code") != 0:
            msg = data.get("msg", "")
            if "登录" in msg:
                log("⚠️ 会话过期，尝试重新登录...")
                self.access_token = ""
                if self.login():
                    return self.do_checkin()
            log(f"❌ 获取签到时段失败: {msg}")
            return False

        rng = data.get("data", {}).get("Range", {})
        now = time.time()
        if now < rng.get("StartTime", 0) or now > rng.get("EndTime", 0):
            log("❌ 不在签到时段")
            return False

        # 提交签到
        sign_info = json.dumps({
            "Reason": "",
            "AttachmentFileName": "",
            "LngLat": f"{self.lng},{self.lat}",
            "Address": f"{self.school}{self.campus}校区"
        })
        resp = self.session.post(
            "https://api.uyiban.com/nightAttendance/student/index/signIn?CSRF=00000",
            data={
                "Code": "",
                "PhoneModel": "",
                "SignInfo": sign_info,
                "OutState": "1"
            },
            headers={"Origin": "https://c.uyiban.com", "User-Agent": UA, "AppVersion": APP_VERSION}
        )
        result = resp.json()
        log(f"签到返回: {json.dumps(result, ensure_ascii=False)[:200]}")

        if result.get("code") == 0:
            log("✅ API 签到成功")
            return True

        log(f"❌ 签到失败: {result.get('msg', '未知错误')}")
        return False


# ============================================================
# 主入口
# ============================================================

def main():
    phone    = sys.argv[1]  if len(sys.argv) > 1  else os.environ.get("YIBAN_PHONE", "")
    password = sys.argv[2]  if len(sys.argv) > 2  else os.environ.get("YIBAN_PASSWORD", "")
    lat      = sys.argv[3]  if len(sys.argv) > 3  else os.environ.get("YIBAN_LAT", "24.571")
    lng      = sys.argv[4]  if len(sys.argv) > 4  else os.environ.get("YIBAN_LNG", "118.617")
    school   = sys.argv[5]  if len(sys.argv) > 5  else os.environ.get("YIBAN_SCHOOL", "福州大学")
    campus   = sys.argv[6]  if len(sys.argv) > 6  else os.environ.get("YIBAN_CAMPUS", "晋江")
    act      = sys.argv[7]  if len(sys.argv) > 7  else os.environ.get("YIBAN_ACT", "iapp7463")
    client_id = sys.argv[8] if len(sys.argv) > 8  else os.environ.get("YIBAN_CLIENT_ID", "95626fa3080300ea")

    if not phone or not password:
        log("❌ 缺少手机号或密码")
        log("用法: python3 cloud_checkin.py <手机号> <密码> [纬度] [经度] [学校] [校区] [act] [client_id]")
        log("或设置环境变量: YIBAN_PHONE YIBAN_PASSWORD YIBAN_ACT YIBAN_CLIENT_ID")
        sys.exit(1)

    log(f"========== 云签到开始 ==========")
    log(f"手机号: {phone[:3]}****{phone[-4:]}")
    log(f"位置: ({lat}, {lng}) {school}{campus}校区")
    log(f"App: act={act}")

    yb = YibanCloud(phone, password, lat, lng, school, campus,
                    act=act, client_id=client_id)

    if not yb.login():
        push_to_phone("易班签到 ❌", "登录失败，请检查密码是否正确")
        sys.exit(1)

    if yb.do_checkin():
        push_to_phone("易班签到 ✓", f"[云签到] {time.strftime('%H:%M')} 签到成功")
        sys.exit(0)
    else:
        push_to_phone("易班签到 ❌", "[云签到] 签到失败，请检查易班 App")
        sys.exit(1)


if __name__ == "__main__":
    main()
