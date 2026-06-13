"""
yiban-checkin Cloud Service — FastAPI Backend

Endpoints:
  POST /api/register          — Create account (with phone)
  POST /api/login             — Login → JWT
  GET  /api/me                — User profile + subscription
  PUT  /api/me/config         — Update yiban credentials
  GET  /api/me/history        — Check-in history
  POST /api/me/checkin        — Trigger immediate check-in
  POST /api/me/payment-link   — Generate 爱发电 payment link
  GET  /api/health            — Basic health check
  GET  /api/health/detailed   — Detailed stats (admin)
  POST /api/webhook/afdian    — 爱发电 payment webhook
  POST /api/admin/notify      — Broadcast notification to paid users
"""

import hashlib
import logging
import os
import urllib.parse
from datetime import datetime, timezone, timedelta
from contextlib import asynccontextmanager
from typing import Optional

from fastapi import FastAPI, Depends, HTTPException, status, Request, Form, Response
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from fastapi.responses import HTMLResponse, RedirectResponse
from pydantic import BaseModel
from sqlalchemy.orm import Session
from jose import jwt
from apscheduler.schedulers.background import BackgroundScheduler

from config import CHECKIN_HOUR, CHECKIN_MINUTE, AFDIAN_TOKEN, JWT_EXPIRE_DAYS, JWT_ALGORITHM, JWT_SECRET
from models import init_db, get_db, User, CheckinLog
from auth import (
    hash_password, verify_password, create_access_token,
    get_current_user, encrypt_config, decrypt_config, subscription_active,
)

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("server")

# ============================================================
# Startup / Scheduler
# ============================================================

scheduler = BackgroundScheduler()


def scheduled_checkin():
    from checkin_worker import run_daily_checkin
    run_daily_checkin()


def scheduled_monitor():
    from monitor import check_and_alert
    check_and_alert()


@asynccontextmanager
async def lifespan(app: FastAPI):
    # 安全检查
    from config import JWT_SECRET, CREDENTIAL_ENCRYPTION_KEY
    if not JWT_SECRET:
        logger.error("❌ JWT_SECRET 未设置！服务器拒绝启动。请在环境变量中设置 JWT_SECRET")
        raise RuntimeError("JWT_SECRET is required")
    if not CREDENTIAL_ENCRYPTION_KEY:
        logger.error("❌ CREDENTIAL_ENCRYPTION_KEY 未设置！服务器拒绝启动。请设置 CREDENTIAL_ENCRYPTION_KEY")
        raise RuntimeError("CREDENTIAL_ENCRYPTION_KEY is required")

    init_db()
    scheduler.add_job(scheduled_checkin, "cron", hour=CHECKIN_HOUR, minute=CHECKIN_MINUTE,
                      timezone="Asia/Shanghai")
    scheduler.add_job(scheduled_monitor, "cron", hour=22, minute=30, timezone="Asia/Shanghai")
    scheduler.start()
    logger.info(f"每日签到: {CHECKIN_HOUR}:{CHECKIN_MINUTE:02d} CST | 每日告警: 22:30 CST")
    yield
    scheduler.shutdown()


app = FastAPI(title="yiban-checkin Cloud", version="2.0.0", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# === Web frontend ===
app.mount("/static", StaticFiles(directory="static"), name="static")
templates = Jinja2Templates(directory="templates")
def _html(path):
    try:
        with open(f"static/{path}") as f:
            return HTMLResponse(content=f.read())
    except:
        return HTMLResponse(content="<h1>Not Found</h1>")

# WEB_COOKIE_NAME for browser sessions (separate from API Bearer)
WEB_COOKIE_NAME = "yiban_session"


def _web_user(request: Request, db: Session):
    """从 Cookie 中解析 JWT，返回 User 或 None。"""
    token = request.cookies.get(WEB_COOKIE_NAME)
    if not token:
        return None
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
        user_id = int(payload.get("sub"))
        return db.query(User).filter(User.id == user_id).first()
    except Exception:
        return None


def _require_web(request: Request, db: Session):
    """Web 页面认证。返回 (user, error_redirect)。
    如果 error_redirect 不为 None，调用者应直接 return 它。"""
    user = _web_user(request, db)
    if user:
        return user, None
    return None, RedirectResponse("/login?need_login=1", status_code=302)

# ============================================================
# Schemas
# ============================================================

class RegisterRequest(BaseModel):
    email: str
    password: str
    phone: str = ""  # 手机号（用于签到，可选）

class LoginRequest(BaseModel):
    email: str
    password: str

class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    user_id: int

class YibanConfigRequest(BaseModel):
    phone: str
    password: str
    school: str = "福州大学"
    campus: str = "晋江"
    lat: float = 24.571
    lng: float = 118.617
    act: str = "iapp7463"
    client_id: str = "95626fa3080300ea"
    push_key: str = ""

class UserProfile(BaseModel):
    email: str
    phone: str = ""
    tier: str
    expires_at: Optional[datetime] = None
    subscription_active: bool
    has_config: bool
    created_at: datetime

    class Config:
        from_attributes = True

class CheckinLogResponse(BaseModel):
    id: int
    created_at: datetime
    success: bool
    method: str
    message: str

    class Config:
        from_attributes = True

class NotifyRequest(BaseModel):
    title: str
    body: str
    admin_key: str

# ============================================================
# Web Routes (浏览器访问)
# ============================================================

@app.get("/admin", response_class=HTMLResponse)
def admin_panel():
    return _html("admin.html")

@app.get("/disclaimer", response_class=HTMLResponse)
def disclaimer():
    return _html("disclaimer.html")

# ============================================================
# School Database
# ============================================================

SCHOOL_DB = [
    {"name":"福州大学","campuses":[{"name":"旗山","lat":26.0732,"lng":119.1932},{"name":"晋江","lat":24.5580,"lng":118.5874},{"name":"铜盘","lat":26.1043,"lng":119.2800},{"name":"集美","lat":24.5910,"lng":118.0970}],"act":"iapp7463","client_id":"95626fa3080300ea"},
    {"name":"厦门大学","campuses":[{"name":"思明","lat":24.4393,"lng":118.0893},{"name":"翔安","lat":24.6075,"lng":118.3185},{"name":"漳州","lat":24.4265,"lng":117.9790}],"act":"","client_id":""},
    {"name":"福建师范大学","campuses":[{"name":"旗山","lat":26.0415,"lng":119.2073},{"name":"仓山","lat":26.0417,"lng":119.3027}],"act":"","client_id":""},
    {"name":"福建农林大学","campuses":[{"name":"金山","lat":26.0847,"lng":119.2330},{"name":"旗山","lat":26.0488,"lng":119.1950}],"act":"","client_id":""},
    {"name":"华侨大学","campuses":[{"name":"厦门","lat":24.6060,"lng":118.0828},{"name":"泉州","lat":24.8760,"lng":118.5960}],"act":"","client_id":""},
    {"name":"集美大学","campuses":[{"name":"主校区","lat":24.5856,"lng":118.0997}],"act":"","client_id":""},
    {"name":"北京大学","campuses":[{"name":"燕园","lat":39.9920,"lng":116.3050}],"act":"","client_id":""},
    {"name":"清华大学","campuses":[{"name":"主校区","lat":40.0070,"lng":116.3240}],"act":"","client_id":""},
    {"name":"北京理工大学","campuses":[{"name":"中关村","lat":39.9606,"lng":116.3167},{"name":"良乡","lat":39.7320,"lng":116.1430}],"act":"","client_id":""},
    {"name":"复旦大学","campuses":[{"name":"邯郸","lat":31.2975,"lng":121.4997},{"name":"江湾","lat":31.3397,"lng":121.5070}],"act":"","client_id":""},
    {"name":"上海交通大学","campuses":[{"name":"闵行","lat":31.0250,"lng":121.4365},{"name":"徐汇","lat":31.2000,"lng":121.4320}],"act":"","client_id":""},
    {"name":"同济大学","campuses":[{"name":"四平路","lat":31.2850,"lng":121.4987},{"name":"嘉定","lat":31.2900,"lng":121.2190}],"act":"","client_id":""},
    {"name":"中山大学","campuses":[{"name":"广州南","lat":23.0530,"lng":113.3750},{"name":"广州东","lat":23.1400,"lng":113.2960},{"name":"珠海","lat":22.3550,"lng":113.5610},{"name":"深圳","lat":22.5300,"lng":113.9530}],"act":"","client_id":""},
    {"name":"华南理工大学","campuses":[{"name":"五山","lat":23.1530,"lng":113.3400},{"name":"大学城","lat":23.0530,"lng":113.3950}],"act":"","client_id":""},
    {"name":"深圳大学","campuses":[{"name":"粤海","lat":22.5350,"lng":113.9400},{"name":"丽湖","lat":22.5940,"lng":113.9670}],"act":"","client_id":""},
    {"name":"暨南大学","campuses":[{"name":"石牌","lat":23.1280,"lng":113.3480},{"name":"番禺","lat":23.0460,"lng":113.3950},{"name":"珠海","lat":22.3510,"lng":113.5540}],"act":"","client_id":""},
    {"name":"浙江大学","campuses":[{"name":"紫金港","lat":30.3050,"lng":120.0860},{"name":"玉泉","lat":30.2640,"lng":120.1270},{"name":"西溪","lat":30.2760,"lng":120.1370},{"name":"之江","lat":30.2150,"lng":120.1230}],"act":"","client_id":""},
    {"name":"武汉大学","campuses":[{"name":"主校区","lat":30.5410,"lng":114.3630}],"act":"","client_id":""},
    {"name":"华中科技大学","campuses":[{"name":"主校区","lat":30.5140,"lng":114.4160}],"act":"","client_id":""},
    {"name":"四川大学","campuses":[{"name":"望江","lat":30.6290,"lng":104.0800},{"name":"江安","lat":30.5570,"lng":103.9930}],"act":"","client_id":""},
    {"name":"重庆大学","campuses":[{"name":"A区","lat":29.5670,"lng":106.4680},{"name":"虎溪","lat":29.5960,"lng":106.3080}],"act":"","client_id":""},
    {"name":"南京大学","campuses":[{"name":"仙林","lat":32.1170,"lng":118.9580},{"name":"鼓楼","lat":32.0580,"lng":118.7800}],"act":"","client_id":""},
    {"name":"东南大学","campuses":[{"name":"九龙湖","lat":31.8880,"lng":118.8250},{"name":"四牌楼","lat":32.0550,"lng":118.7920}],"act":"","client_id":""},
    {"name":"中国科学技术大学","campuses":[{"name":"东区","lat":31.8350,"lng":117.2710},{"name":"西区","lat":31.8330,"lng":117.2580}],"act":"","client_id":""},
    {"name":"西安交通大学","campuses":[{"name":"兴庆","lat":34.2460,"lng":108.9870},{"name":"雁塔","lat":34.2210,"lng":108.9870}],"act":"","client_id":""},
    {"name":"哈尔滨工业大学","campuses":[{"name":"主校区","lat":45.7460,"lng":126.6340},{"name":"深圳","lat":22.5900,"lng":113.9570},{"name":"威海","lat":37.5310,"lng":122.0730}],"act":"","client_id":""},
]

@app.get("/api/schools")
def api_schools(q: str = ""):
    """学校搜索 API。q 为空返回全部，否则按名称模糊匹配。"""
    q = q.strip()
    if not q:
        return SCHOOL_DB
    ql = q.lower()
    return [s for s in SCHOOL_DB if ql in s["name"].lower() or q in s["name"]]

@app.get("/", response_class=HTMLResponse)
def web_index():
    try:
        with open("static/index.html", "r") as f:
            return HTMLResponse(content=f.read())
    except:
        return HTMLResponse(content="<h1>Loading...</h1>")
@app.get("/login", response_class=HTMLResponse)
def web_login_page():
    return _html("login.html")

@app.post("/login")
def web_login_submit(request: Request, email: str = Form(...), password: str = Form(...),
                     db: Session = Depends(get_db)):
    user = db.query(User).filter(User.email == email).first()
    if not user or not verify_password(password, user.hashed_password):
        return RedirectResponse("/login?error=" + urllib.parse.quote("邮箱或密码错误"), status_code=302)
    token = create_access_token(user.id)
    resp = RedirectResponse("/dashboard", status_code=302)
    resp.set_cookie(WEB_COOKIE_NAME, token, max_age=JWT_EXPIRE_DAYS * 86400,
                    httponly=True, samesite="lax")
    return resp


@app.get("/register", response_class=HTMLResponse)
def web_register_page():
    return _html("register.html")


@app.post("/register")
def web_register_submit(request: Request, email: str = Form(...), password: str = Form(...),
                        phone: str = Form(""), db: Session = Depends(get_db)):
    if db.query(User).filter(User.email == email).first():
        return RedirectResponse("/register?error=" + urllib.parse.quote("该邮箱已注册"), status_code=302)
    if len(password) < 6:
        return RedirectResponse("/register?error=" + urllib.parse.quote("密码至少 6 位"), status_code=302)

    user = User(email=email, hashed_password=hash_password(password))
    if phone:
        user.yiban_config = encrypt_config({"phone": phone, "password": "", "school": "",
                                             "campus": "", "lat": 0, "lng": 0, "act": "", "client_id": ""})
    db.add(user)
    db.commit()
    token = create_access_token(user.id)
    resp = RedirectResponse("/dashboard", status_code=302)
    resp.set_cookie(WEB_COOKIE_NAME, token, max_age=JWT_EXPIRE_DAYS * 86400,
                    httponly=True, samesite="lax")
    return resp


@app.get("/logout")
def web_logout():
    resp = RedirectResponse("/", status_code=302)
    resp.delete_cookie(WEB_COOKIE_NAME)
    return resp


@app.get("/dashboard", response_class=HTMLResponse)
def web_dashboard(request: Request, db: Session = Depends(get_db)):
    user, err = _require_web(request, db)
    if err:
        return err

    config = decrypt_config(user.yiban_config)
    tier_map = {"free": "免费", "monthly": "月付", "yearly": "年付", "lifetime": "永久"}
    tier_display = tier_map.get(user.tier, user.tier)
    has_config = bool(user.yiban_config) and bool(config.get("phone"))
    sub_active = subscription_active(user)

    # 签到统计
    today = datetime.now(timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0)
    today_logs = db.query(CheckinLog).filter(
        CheckinLog.user_id == user.id, CheckinLog.created_at >= today
    ).all()
    month_start = today.replace(day=1)
    month_logs = db.query(CheckinLog).filter(
        CheckinLog.user_id == user.id, CheckinLog.created_at >= month_start
    ).all()

    # 连续签到
    streak = 0
    logs_by_date = {}
    for log in month_logs:
        d = log.created_at.strftime("%Y-%m-%d")
        if d not in logs_by_date or log.success:
            logs_by_date[d] = log.success
    check_date = today
    for _ in range(31):
        d = check_date.strftime("%Y-%m-%d")
        if logs_by_date.get(d):
            streak += 1
            check_date -= timedelta(days=1)
        else:
            break

    today_success = sum(1 for l in today_logs if l.success)
    month_success = sum(1 for l in month_logs if l.success)

    # 7天热力图
    week_days_labels = ["一","二","三","四","五","六","日"]
    import calendar as _cal
    days_in_month = _cal.monthrange(today.year, today.month)[1]
    week_strip = ""
    for i in range(6, -1, -1):
        d = today - timedelta(days=i)
        dk = d.strftime("%Y-%m-%d")
        ok = logs_by_date.get(dk, None)
        if ok is True:
            cls = "dot-ok"
        elif ok is False:
            cls = "dot-fail"
        elif d > today:
            cls = "dot-future"
        else:
            cls = "dot-miss"
        week_strip += f'<div class="dot-cell"><div class="dot {cls}" title="{d.strftime("%m/%d")}"></div><span class="dot-label">{week_days_labels[d.weekday()]}</span></div>'

    # 本月进度
    progress_pct = min(100, int(month_success / days_in_month * 100)) if days_in_month else 0

    # 签到记录（最近10条）
    history_rows = ""
    history_logs = db.query(CheckinLog).filter(
        CheckinLog.user_id == user.id
    ).order_by(CheckinLog.created_at.desc()).limit(10).all()
    for l in history_logs:
        icon = "✅" if l.success else "❌"
        t = l.created_at.strftime("%m-%d %H:%M")
        msg = (l.message or "")[:40]
        history_rows += f'<tr><td>{icon}</td><td>{t}</td><td>{l.method}</td><td>{msg}</td></tr>'

    # 页面消息
    success_msg = request.query_params.get("success", "")
    error_msg = request.query_params.get("error", "")
    msg_html = ""
    if success_msg:
        msg_html = f'<div style="background:#d4edda;color:#155724;padding:10px 16px;border-radius:8px;margin-bottom:16px">{success_msg}</div>'
    if error_msg:
        msg_html = f'<div style="background:#f8d7da;color:#721c24;padding:10px 16px;border-radius:8px;margin-bottom:16px">{error_msg}</div>'

    html = f"""<!DOCTYPE html><html lang="zh-CN"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><title>控制台</title>
<style>
*{{box-sizing:border-box}}body{{font-family:-apple-system,sans-serif;background:#f5f5f7;max-width:800px;margin:0 auto;padding:24px 16px 60px;color:#1d1d1f}}
h1{{font-size:26px;margin:0}}.email{{color:#888;font-size:14px}}.badge{{display:inline-block;padding:3px 10px;border-radius:12px;font-size:12px;font-weight:600}}
.badge-pro{{background:#007aff;color:#fff}}.badge-free{{background:#e5e5ea;color:#666}}
.nav{{display:flex;gap:16px;margin-bottom:20px;flex-wrap:wrap}}.nav a{{color:#007aff;text-decoration:none;font-size:14px}}
.card{{background:#fff;border-radius:14px;padding:20px 24px;box-shadow:0 1px 3px rgba(0,0,0,.04);margin:16px 0}}
.stats{{display:flex;gap:10px;flex-wrap:wrap;margin:16px 0}}
.stat{{flex:1;min-width:80px;background:#f5f5f7;border-radius:10px;padding:14px;text-align:center}}
.stat .n{{font-size:24px;font-weight:700;color:#007aff}}.stat .l{{font-size:11px;color:#888}}
.btn{{display:inline-block;padding:10px 22px;border-radius:10px;text-decoration:none;font-weight:600;margin:8px 8px 8px 0;font-size:15px;cursor:pointer;border:none}}
.btn-p{{background:#007aff;color:#fff}}.btn-o{{color:#007aff;border:1px solid #007aff;background:#fff}}
.btn-p:active{{opacity:.8}}
table{{width:100%;border-collapse:collapse;font-size:13px}}td,th{{padding:8px 12px;border-bottom:1px solid #f0f0f0;text-align:left}}
/* Week strip */
.week-strip{{display:flex;gap:8px;align-items:flex-end;justify-content:center;margin:16px 0}}
.dot-cell{{display:flex;flex-direction:column;align-items:center;gap:6px}}
.dot{{width:36px;height:36px;border-radius:10px;transition:transform .2s}}
.dot:hover{{transform:scale(1.15)}}
.dot-ok{{background:#34c759}}.dot-fail{{background:#ff3b30}}.dot-miss{{background:#e5e5ea}}.dot-future{{background:#fff;border:2px dashed #d2d2d7}}
.dot-label{{font-size:11px;color:#999;font-weight:500}}
/* Progress */
.progress-bar{{height:8px;background:#e5e5ea;border-radius:4px;margin:8px 0;overflow:hidden}}
.progress-fill{{height:100%;background:linear-gradient(90deg,#007aff,#34c759);border-radius:4px;transition:width .5s}}
/* Countdown */
.countdown{{display:inline-block;background:#f0f4ff;color:#007aff;padding:4px 12px;border-radius:16px;font-size:14px;font-weight:600;margin-left:8px}}
footer{{text-align:center;padding:24px;font-size:12px;color:#aaa;border-top:1px solid #e5e5e5;margin-top:32px}}
</style></head>
<body>
<div class=nav><a href=/>首页</a><a href=/config>配置</a><a href=/profile>账号</a><a href=/logout>退出</a></div>
<h1>📊 控制台</h1>
<p class=email>{user.email} <span class="badge {'badge-pro' if sub_active else 'badge-free'}">{tier_display}{' · 有效' if sub_active else ''}</span><span class=countdown id=countdown>⏳ 计算中…</span></p>
{msg_html}

<div class=stats>
<div class=stat><div class=n id=todayStat>{today_success}</div><div class=l>今日签到</div></div>
<div class=stat><div class=n>{month_success}<span style=font-size:14px;color:#888>/{days_in_month}</span></div><div class=l>本月签到</div></div>
<div class=stat><div class=n>{streak}</div><div class=l>连续签到</div></div>
</div>

<div class=card>
<h3 style=margin:0>📅 最近7天</h3>
<div class=week-strip>{week_strip}</div>
<div style=margin-top:12px>
  <div style=display:flex;justify-content:space-between;font-size:12px;color:#888><span>本月完成度</span><span>{month_success}/{days_in_month} ({progress_pct}%)</span></div>
  <div class=progress-bar><div class=progress-fill style=width:{progress_pct}%></div></div>
</div>
</div>

<div class=card>
<h3 style=margin:0>签到操作</h3>
<p style="color:#888;font-size:13px;margin:12px 0">{'✅ 已配置签到信息' if has_config else '⚠️ 尚未配置签到信息，请先配置'}</p>
<form method=POST action=/dashboard/checkin style=display:inline onsubmit="this.querySelector('button').disabled=true;this.querySelector('button').textContent='签到中…'">
  <button type=submit class="btn btn-p">🔄 立即云签到</button>
</form>
<a href=/config class="btn btn-o">📝 修改配置</a>
</div>

<div class=card>
<h3 style=margin:0>签到记录</h3>
<table><tr><th></th><th>时间</th><th>方式</th><th>消息</th></tr>{history_rows}</table>
<p style=margin-top:12px><a href=/history style=color:#007aff;font-size:13px;text-decoration:none>查看全部 →</a></p>
</div>
<footer>yiban-checkin · 每日 {CHECKIN_HOUR}:{CHECKIN_MINUTE:02d} 自动签到</footer>
<script>
// Countdown to next checkin
(function() {{
  function updateCountdown() {{
    var now = new Date();
    var target = new Date(now);
    target.setHours({CHECKIN_HOUR}, {CHECKIN_MINUTE}, 0, 0);
    if (now >= target) target.setDate(target.getDate() + 1);
    var diff = Math.floor((target - now) / 1000);
    if (diff <= 0) {{ document.getElementById('countdown').textContent = '签到中…'; return; }}
    var h = Math.floor(diff / 3600);
    var m = Math.floor((diff % 3600) / 60);
    var s = diff % 60;
    var el = document.getElementById('countdown');
    if (diff < 600) el.style.background = '#fff3cd'; el.style.color = '#856404';
    else if (diff < 3600) el.style.background = '#f0f4ff'; el.style.color = '#007aff';
    else {{ el.style.background = '#f0f4ff'; el.style.color = '#007aff'; }}
    el.textContent = '⏳ ' + (h>0?h+'时':'') + m + '分' + s + '秒后签到';
  }}
  updateCountdown();
  setInterval(updateCountdown, 1000);
}})();
</script>
</body></html>"""
    return HTMLResponse(content=html)


@app.post("/dashboard/checkin")
def web_trigger_checkin(request: Request, db: Session = Depends(get_db)):
    user, err = _require_web(request, db)
    if err:
        return err
    if not user.yiban_config:
        return RedirectResponse("/config?error=请先配置签到信息", status_code=302)
    from checkin_worker import run_checkin_for_user
    log = run_checkin_for_user(user)
    db.add(log)
    db.commit()
    if log.success:
        return RedirectResponse("/dashboard?success=" + urllib.parse.quote("签到成功"), status_code=302)
    else:
        return RedirectResponse("/dashboard?error=" + urllib.parse.quote(log.message or "签到失败"), status_code=302)


@app.get("/config", response_class=HTMLResponse)
def web_config_page(request: Request, db: Session = Depends(get_db)):
    user, err = _require_web(request, db)
    if err:
        return err
    import json as _json
    config = decrypt_config(user.yiban_config) if user.yiban_config else {}
    phone = config.get("phone", "")
    school = config.get("school", "")
    campus = config.get("campus", "")
    lat = config.get("lat", 0.0)
    lng = config.get("lng", 0.0)
    act = config.get("act", "")
    client_id = config.get("client_id", "")
    push_key = user.push_key or ""

    error_msg = request.query_params.get("error", "")
    err_html = f'<div style="background:#f8d7da;color:#721c24;padding:10px 16px;border-radius:8px;margin-bottom:16px">{error_msg}</div>' if error_msg else ""

    schools_json = _json.dumps(SCHOOL_DB, ensure_ascii=False)

    html = f"""<!DOCTYPE html><html lang="zh-CN"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><title>签到配置</title>
<style>
*{{box-sizing:border-box}}body{{font-family:-apple-system,sans-serif;background:#f5f5f7;max-width:640px;margin:0 auto;padding:24px 16px 60px;color:#1d1d1f}}
.card{{background:#fff;border-radius:14px;padding:24px;box-shadow:0 1px 3px rgba(0,0,0,.06)}}h1{{font-size:26px;margin:0 0 12px}}
label{{display:block;font-size:13px;font-weight:600;color:#555;margin:14px 0 4px}}
input,select{{width:100%;padding:10px 12px;border:1px solid #d2d2d7;border-radius:8px;font-size:15px;background:#fff}}
input:focus,select:focus{{outline:none;border-color:#007aff;box-shadow:0 0 0 3px rgba(0,122,255,.15)}}
.row{{display:flex;gap:12px}}.row>div{{flex:1}}
button{{width:100%;padding:12px;background:#007aff;color:#fff;border:none;border-radius:10px;font-size:16px;font-weight:600;cursor:pointer;margin-top:24px;transition:opacity .2s}}
button:active{{opacity:.8}}
.nav{{display:flex;gap:16px;margin-bottom:20px}}.nav a{{color:#007aff;text-decoration:none;font-size:14px}}
.hint{{font-size:12px;color:#999;margin-top:2px}}.hint a{{color:#007aff}}
/* School picker */
.picker{{position:relative}}
.dropdown{{position:absolute;top:100%;left:0;right:0;background:#fff;border:1px solid #d2d2d7;border-radius:0 0 10px 10px;max-height:220px;overflow-y:auto;z-index:10;display:none;box-shadow:0 4px 12px rgba(0,0,0,.08)}}
.dropdown.show{{display:block}}
.dropdown .item{{padding:10px 14px;cursor:pointer;font-size:14px;border-bottom:1px solid #f0f0f0}}
.dropdown .item:hover,.dropdown .item.active{{background:#f0f4ff;color:#007aff}}
.dropdown .item .region{{font-size:11px;color:#aaa;float:right;margin-top:2px}}
.no-match{{padding:12px 14px;color:#999;font-size:13px;text-align:center}}
.tag{{display:inline-block;background:#e8f5e9;color:#2e7d32;padding:2px 8px;border-radius:4px;font-size:11px;margin-left:6px;vertical-align:middle}}
.advanced{{background:#fafafa;border-radius:10px;padding:16px;margin-top:16px}}
.advanced h4{{margin:0 0 8px;font-size:13px;color:#888}}
</style></head>
<body><div class=nav><a href=/>首页</a><a href=/dashboard>控制台</a><a href=/profile>账号</a><a href=/logout>退出</a></div>
<h1>⚙️ 签到配置</h1><p style="color:#888;margin-bottom:20px;font-size:14px">加密存储于服务器，仅用于每日自动签到</p>
{err_html}
<div class=card>
<form method=POST action=/config id=cfgForm>
<label>易班手机号</label><input name=phone id=phone placeholder="11位手机号" value="{phone}" required autocomplete=off>

<label>易班密码</label><input type=password name=password placeholder="易班密码" required autocomplete=off>

<label>学校 <span style="font-weight:400;color:#999;font-size:12px">搜索选择</span></label>
<div class=picker>
  <input id=schoolInput placeholder="输入学校名称搜索…" value="{school}" autocomplete=off>
  <input type=hidden name=school id=schoolHidden value="{school}">
  <div class=dropdown id=schoolDropdown></div>
</div>

<label>校区</label>
<select name=campus id=campusSelect>
  <option value="">请先选择学校</option>
</select>

<div class=row><div><label>纬度</label><input name=lat id=latInput value="{lat}" type=number step=0.0001 required></div><div><label>经度</label><input name=lng id=lngInput value="{lng}" type=number step=0.0001 required></div></div>

<div id=advancedSection class=advanced>
  <h4>🔧 校本化参数（高级）</h4>
  <label>校本化 App ID</label><input name=act id=actInput placeholder="例如 iapp7463" value="{act}">
  <label>OAuth Client ID</label><input name=client_id id=clientIdInput placeholder="例如 95626fa3080300ea" value="{client_id}">
</div>

<label>Server酱 SendKey <span style="font-weight:400;color:#999;font-size:12px">可选，用于微信通知</span></label>
<input name=push_key placeholder="留空不推送" value="{push_key}">
<p class=hint>去 <a href="https://sct.ftqq.com" target=_blank>sct.ftqq.com</a> 获取</p>

<button type=submit>💾 保存配置</button>
</form></div>
<script>
var SCHOOLS = {schools_json};
var curSchool = "{school}";
var curCampus = "{campus}";

var schoolInput = document.getElementById('schoolInput');
var schoolHidden = document.getElementById('schoolHidden');
var dropdown = document.getElementById('schoolDropdown');
var campusSelect = document.getElementById('campusSelect');
var latInput = document.getElementById('latInput');
var lngInput = document.getElementById('lngInput');
var actInput = document.getElementById('actInput');
var clientIdInput = document.getElementById('clientIdInput');
var advancedSection = document.getElementById('advancedSection');

var selectedSchoolData = null;

// Region tag helper
function regionTag(name) {{
  var r = {{"福州大学":"福建","厦门大学":"福建","福建师范大学":"福建","福建农林大学":"福建","华侨大学":"福建","集美大学":"福建","北京大学":"北京","清华大学":"北京","北京理工大学":"北京","复旦大学":"上海","上海交通大学":"上海","同济大学":"上海","中山大学":"广东","华南理工大学":"广东","深圳大学":"广东","暨南大学":"广东","浙江大学":"浙江","武汉大学":"湖北","华中科技大学":"湖北","四川大学":"四川","重庆大学":"重庆","南京大学":"江苏","东南大学":"江苏","中国科学技术大学":"安徽","西安交通大学":"陕西","哈尔滨工业大学":"黑龙江"}};
  return r[name] || '';
}}

function showDropdown() {{
  var q = schoolInput.value.trim().toLowerCase();
  var matches = q ? SCHOOLS.filter(function(s){{return s.name.toLowerCase().indexOf(q)!==-1||s.name.indexOf(q)!==-1}}) : SCHOOLS;
  if (matches.length===0) {{
    dropdown.innerHTML = '<div class=no-match>未找到匹配学校，可手动输入</div>';
  }} else {{
    dropdown.innerHTML = matches.map(function(s,i) {{
      return '<div class="item'+(i===0?' active':'')+'" data-idx="'+i+'">'+s.name+'<span class=region>'+regionTag(s.name)+'</span></div>';
    }}).join('');
  }}
  dropdown.classList.add('show');
  selectedIdx = 0;
}}

function hideDropdown() {{ dropdown.classList.remove('show'); }}

var selectedIdx = 0;
schoolInput.addEventListener('keydown', function(e) {{
  if (e.key==='ArrowDown') {{ e.preventDefault(); var items=dropdown.querySelectorAll('.item'); if(items.length){{selectedIdx=Math.min(selectedIdx+1,items.length-1);items.forEach(function(it,i){{it.classList.toggle('active',i===selectedIdx);it.scrollIntoView({{block:'nearest'}});}})}} }}
  else if (e.key==='ArrowUp') {{ e.preventDefault(); var items=dropdown.querySelectorAll('.item'); if(items.length){{selectedIdx=Math.max(selectedIdx-1,0);items.forEach(function(it,i){{it.classList.toggle('active',i===selectedIdx);it.scrollIntoView({{block:'nearest'}});}})}} }}
  else if (e.key==='Enter') {{ e.preventDefault(); var active=dropdown.querySelector('.item.active'); if(active){{ active.click(); }} else {{ hideDropdown(); }} }}
  else if (e.key==='Escape') {{ hideDropdown(); }}
  else {{ showDropdown(); }}
}});
schoolInput.addEventListener('focus', function(){{ showDropdown(); }});
schoolInput.addEventListener('blur', function(){{ setTimeout(hideDropdown, 200); }});

dropdown.addEventListener('mousedown', function(e) {{
  var item = e.target.closest('.item');
  if (!item) {{ schoolInput.focus(); return; }}
  var idx = parseInt(item.dataset.idx);
  var q = schoolInput.value.trim().toLowerCase();
  var matches = q ? SCHOOLS.filter(function(s){{return s.name.toLowerCase().indexOf(q)!==-1||s.name.indexOf(q)!==-1}}) : SCHOOLS;
  var s = matches[idx];
  selectSchool(s);
  hideDropdown();
}});

function selectSchool(s) {{
  selectedSchoolData = s;
  schoolInput.value = s.name;
  schoolHidden.value = s.name;
  // Fill campuses
  campusSelect.innerHTML = s.campuses.map(function(c){{return '<option value="'+c.name+'" data-lat="'+c.lat+'" data-lng="'+c.lng+'">'+c.name+'</option>'}}).join('');
  if (s.campuses.length===1) {{
    campusSelect.value = s.campuses[0].name;
    latInput.value = s.campuses[0].lat;
    lngInput.value = s.campuses[0].lng;
  }} else if (s.campuses.length>1) {{
    // Try to match previous campus
    var found = false;
    for (var i=0;i<s.campuses.length;i++) {{
      if (s.campuses[i].name===curCampus) {{ campusSelect.value=curCampus; latInput.value=s.campuses[i].lat; lngInput.value=s.campuses[i].lng; found=true; break; }}
    }}
    if (!found) {{ campusSelect.selectedIndex=0; latInput.value=s.campuses[0].lat; lngInput.value=s.campuses[0].lng; }}
  }}
  // Fill act/client_id if known
  if (s.act) {{
    actInput.value = s.act;
    clientIdInput.value = s.client_id;
    advancedSection.style.display = 'none';
  }} else {{
    advancedSection.style.display = 'block';
  }}
}}

campusSelect.addEventListener('change', function() {{
  var opt = campusSelect.options[campusSelect.selectedIndex];
  if (opt && opt.dataset.lat) {{
    latInput.value = opt.dataset.lat;
    lngInput.value = opt.dataset.lng;
  }}
}});

// Initialize: if school is pre-filled, load its data
(function init() {{
  if (curSchool) {{
    var found = SCHOOLS.filter(function(s){{return s.name===curSchool}})[0];
    if (found) selectSchool(found);
  }}
  if (curCampus && campusSelect.options.length) {{
    for (var i=0;i<campusSelect.options.length;i++) {{
      if (campusSelect.options[i].value===curCampus) {{ campusSelect.selectedIndex=i; var o=campusSelect.options[i]; if(o.dataset.lat){{latInput.value=o.dataset.lat;lngInput.value=o.dataset.lng;}} break; }}
    }}
  }}
}})();
</script>
</body></html>"""
    return HTMLResponse(content=html)


@app.post("/config")
def web_config_save(request: Request, db: Session = Depends(get_db),
                    phone: str = Form(...), password: str = Form(...),
                    school: str = Form(""), campus: str = Form(""),
                    lat: float = Form(0.0), lng: float = Form(0.0),
                    act: str = Form(""), client_id: str = Form(""),
                    push_key: str = Form("")):
    user, err = _require_web(request, db)
    if err:
        return err
    config = {"phone": phone, "password": password, "school": school, "campus": campus,
              "lat": lat, "lng": lng, "act": act, "client_id": client_id}
    user.yiban_config = encrypt_config(config)
    user.push_key = push_key
    db.commit()
    return RedirectResponse("/dashboard?success=" + urllib.parse.quote("配置已保存"), status_code=302)


@app.get("/history", response_class=HTMLResponse)
def web_history(request: Request, db: Session = Depends(get_db)):
    user, err = _require_web(request, db)
    if err:
        return err
    logs = db.query(CheckinLog).filter(
        CheckinLog.user_id == user.id
    ).order_by(CheckinLog.created_at.desc()).limit(50).all()

    rows = ""
    for l in logs:
        icon = "✅" if l.success else "❌"
        t = l.created_at.strftime("%Y-%m-%d %H:%M")
        msg = (l.message or "")[:60]
        rows += f'<tr><td>{icon}</td><td>{t}</td><td>{l.method}</td><td>{msg}</td></tr>'

    html = f"""<!DOCTYPE html><html lang="zh-CN"><head><meta charset="UTF-8"><title>签到记录</title>
<style>body{{font-family:-apple-system,sans-serif;background:#f5f5f7;max-width:800px;margin:0 auto;padding:40px 24px}}
.card{{background:#fff;border-radius:14px;padding:24px;box-shadow:0 1px 3px rgba(0,0,0,.06);margin:16px 0}}
h1{{font-size:28px}}table{{width:100%;border-collapse:collapse;font-size:14px}}
td,th{{padding:10px 14px;border-bottom:1px solid #f0f0f0;text-align:left}}
.nav{{display:flex;gap:16px;margin-bottom:20px}}.nav a{{color:#007aff;text-decoration:none;font-size:14px}}
</style></head>
<body><div class=nav><a href=/>首页</a><a href=/dashboard>控制台</a><a href=/logout>退出</a></div>
<h1>签到记录</h1><div class=card>
<table><tr><th></th><th>时间</th><th>方式</th><th>消息</th></tr>{rows}</table>
</div></body></html>"""
    return HTMLResponse(content=html)


@app.get("/profile", response_class=HTMLResponse)
def web_profile(request: Request, db: Session = Depends(get_db)):
    user, err = _require_web(request, db)
    if err:
        return err
    config = decrypt_config(user.yiban_config) if user.yiban_config else {}
    phone = config.get("phone", "") or ""
    school = config.get("school", "") or ""
    sub_active = subscription_active(user)
    tier_map = {"free": "免费", "monthly": "月付", "yearly": "年付", "lifetime": "永久"}
    tier_display = tier_map.get(user.tier, user.tier)
    expires = user.expires_at.strftime("%Y-%m-%d") if user.expires_at else "无"

    success_msg = request.query_params.get("success", "")
    error_msg = request.query_params.get("error", "")
    msg_html = ""
    if success_msg:
        msg_html = f'<div style="background:#d4edda;color:#155724;padding:10px 16px;border-radius:8px;margin-bottom:16px">{success_msg}</div>'
    if error_msg:
        msg_html = f'<div style="background:#f8d7da;color:#721c24;padding:10px 16px;border-radius:8px;margin-bottom:16px">{error_msg}</div>'

    html = f"""<!DOCTYPE html><html lang="zh-CN"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><title>个人中心</title>
<style>
*{{box-sizing:border-box}}body{{font-family:-apple-system,sans-serif;background:#f5f5f7;max-width:640px;margin:0 auto;padding:24px 16px 60px;color:#1d1d1f}}
h1{{font-size:26px;margin:0}}.card{{background:#fff;border-radius:14px;padding:20px 24px;box-shadow:0 1px 3px rgba(0,0,0,.04);margin:16px 0}}
label{{display:block;font-size:13px;font-weight:600;color:#555;margin:12px 0 4px}}
input{{width:100%;padding:10px 12px;border:1px solid #d2d2d7;border-radius:8px;font-size:15px;background:#fff}}
input:focus{{outline:none;border-color:#007aff;box-shadow:0 0 0 3px rgba(0,122,255,.15)}}
button{{width:100%;padding:12px;background:#007aff;color:#fff;border:none;border-radius:10px;font-size:16px;font-weight:600;cursor:pointer;margin-top:16px}}
button.danger{{background:#ff3b30}}
.nav{{display:flex;gap:16px;margin-bottom:20px;flex-wrap:wrap}}.nav a{{color:#007aff;text-decoration:none;font-size:14px}}
.info-row{{display:flex;justify-content:space-between;padding:10px 0;border-bottom:1px solid #f0f0f0;font-size:14px}}
.info-row .v{{color:#555}}
.badge{{display:inline-block;padding:3px 10px;border-radius:12px;font-size:12px;font-weight:600}}
.badge-pro{{background:#007aff;color:#fff}}.badge-free{{background:#e5e5ea;color:#666}}
</style></head>
<body>
<div class=nav><a href=/>首页</a><a href=/dashboard>控制台</a><a href=/config>配置</a><a href=/logout>退出</a></div>
<h1>👤 个人中心</h1>
{msg_html}

<div class=card>
<h3 style=margin:0>账号信息</h3>
<div class=info-row><span>邮箱</span><span class=v>{user.email}</span></div>
<div class=info-row><span>会员</span><span class=v><span class="badge {'badge-pro' if sub_active else 'badge-free'}">{tier_display}</span></span></div>
<div class=info-row><span>到期时间</span><span class=v>{expires}</span></div>
<div class=info-row><span>绑定手机</span><span class=v>{phone or '未设置'}</span></div>
<div class=info-row><span>学校</span><span class=v>{school or '未设置'}</span></div>
<div class=info-row><span>注册时间</span><span class=v>{user.created_at.strftime("%Y-%m-%d")}</span></div>
</div>

<div class=card>
<h3 style=margin:0>🔒 修改密码</h3>
<form method=POST action=/profile/password>
<label>原密码</label><input type=password name=old_password placeholder="输入原密码" required autocomplete=off>
<label>新密码</label><input type=password name=new_password placeholder="至少 6 位" required minlength=6 autocomplete=off>
<button type=submit>更新密码</button>
</form>
</div>

<div class=card>
<h3 style=margin:0>💎 升级会员</h3>
<p style="color:#888;font-size:13px;margin:8px 0">解锁每日自动云签到、微信通知</p>
<a href=https://afdian.com/a/yiban-checkin target=_blank style="display:block;text-align:center;padding:12px;background:#ff6b35;color:#fff;border-radius:10px;text-decoration:none;font-weight:600;font-size:15px">前往爱发电赞助 &rarr;</a>
</div>

</body></html>"""
    return HTMLResponse(content=html)


@app.post("/profile/password")
def web_change_password(request: Request, db: Session = Depends(get_db),
                        old_password: str = Form(...), new_password: str = Form(...)):
    user, err = _require_web(request, db)
    if err:
        return err
    if not verify_password(old_password, user.hashed_password):
        return RedirectResponse("/profile?error=" + urllib.parse.quote("原密码错误"), status_code=302)
    if len(new_password) < 6:
        return RedirectResponse("/profile?error=" + urllib.parse.quote("新密码至少 6 位"), status_code=302)
    user.hashed_password = hash_password(new_password)
    db.commit()
    return RedirectResponse("/profile?success=" + urllib.parse.quote("密码已更新"), status_code=302)

# ============================================================
# API Routes (macOS App 调用)
# ============================================================

@app.post("/api/register", response_model=TokenResponse)
def register(body: RegisterRequest, db: Session = Depends(get_db)):
    if db.query(User).filter(User.email == body.email).first():
        raise HTTPException(status_code=400, detail="该邮箱已注册")
    if len(body.password) < 6:
        raise HTTPException(status_code=400, detail="密码至少 6 位")
    if body.phone and not _valid_phone(body.phone):
        raise HTTPException(status_code=400, detail="手机号格式不正确（11 位数字）")

    user = User(email=body.email, hashed_password=hash_password(body.password))
    # 注册时如果填了手机号，存到 yiban_config 里
    if body.phone:
        user.yiban_config = encrypt_config({"phone": body.phone, "password": "",
                                             "school": "", "campus": "", "lat": 0, "lng": 0,
                                             "act": "", "client_id": ""})
    db.add(user)
    db.commit()
    token = create_access_token(user.id)
    logger.info(f"新用户注册: {body.email}")
    return TokenResponse(access_token=token, user_id=user.id)


@app.post("/api/login", response_model=TokenResponse)
def login(body: LoginRequest, db: Session = Depends(get_db)):
    user = db.query(User).filter(User.email == body.email).first()
    if not user or not verify_password(body.password, user.hashed_password):
        raise HTTPException(status_code=401, detail="邮箱或密码错误")
    token = create_access_token(user.id)
    return TokenResponse(access_token=token, user_id=user.id)


def _valid_phone(phone: str) -> bool:
    phone = phone.strip()
    return len(phone) == 11 and phone.isdigit() and phone.startswith("1")


# ============================================================
# User endpoints (authenticated)
# ============================================================

@app.get("/api/me", response_model=UserProfile)
def get_profile(user: User = Depends(get_current_user)):
    config = decrypt_config(user.yiban_config)
    return UserProfile(
        email=user.email,
        phone=config.get("phone", ""),
        tier=user.tier,
        expires_at=user.expires_at,
        subscription_active=subscription_active(user),
        has_config=bool(user.yiban_config) and bool(config.get("phone")),
        created_at=user.created_at,
    )


@app.put("/api/me/config")
def update_config(body: YibanConfigRequest, user: User = Depends(get_current_user),
                  db: Session = Depends(get_db)):
    config = {
        "phone": body.phone,
        "password": body.password,
        "school": body.school,
        "campus": body.campus,
        "lat": body.lat,
        "lng": body.lng,
        "act": body.act,
        "client_id": body.client_id,
    }
    user.yiban_config = encrypt_config(config)
    user.push_key = body.push_key
    db.commit()
    return {"ok": True}


@app.get("/api/me/history", response_model=list[CheckinLogResponse])
def get_history(user: User = Depends(get_current_user),
                db: Session = Depends(get_db)):
    logs = (
        db.query(CheckinLog)
        .filter(CheckinLog.user_id == user.id)
        .order_by(CheckinLog.created_at.desc())
        .limit(30)
        .all()
    )
    return logs


@app.post("/api/me/checkin")
def trigger_checkin(user: User = Depends(get_current_user),
                    db: Session = Depends(get_db)):
    if not user.yiban_config:
        raise HTTPException(status_code=400, detail="请先配置签到信息")
    from checkin_worker import run_checkin_for_user
    log = run_checkin_for_user(user)
    db.add(log)
    db.commit()
    return {"success": log.success, "message": log.message}


@app.post("/api/me/payment-link")
def get_payment_link(user: User = Depends(get_current_user)):
    """生成爱发电支付链接（带 user_id）"""
    plan_id = "your-plan-id"  # 替换为你的爱发电赞助方案 ID
    return {
        "url": f"https://afdian.com/item/{plan_id}?remark=user_id%3D{user.id}",
        "user_id": user.id,
    }


class PasswordChange(BaseModel):
    old_password: str
    new_password: str


@app.post("/api/me/password")
def change_password(body: PasswordChange, user: User = Depends(get_current_user),
                    db: Session = Depends(get_db)):
    """修改密码"""
    if not verify_password(body.old_password, user.hashed_password):
        raise HTTPException(status_code=400, detail="原密码错误")
    if len(body.new_password) < 6:
        raise HTTPException(status_code=400, detail="新密码至少 6 位")
    user.hashed_password = hash_password(body.new_password)
    db.commit()
    return {"ok": True}

# ============================================================
# Webhook (爱发电)
# ============================================================

@app.post("/api/webhook/afdian")
async def afdian_webhook(request: Request, db: Session = Depends(get_db)):
    """接收爱发电付款通知，自动升级会员"""
    from webhook import handle_order, verify_sign

    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="无效的 JSON")

    # 爱发电 webhook 结构: {"data": {"order": {...}}, "sign": "..."}
    data = body.get("data", {})
    order = data.get("order", {})
    sign = body.get("sign", "")

    # 验证签名
    if not verify_sign(data, sign, AFDIAN_TOKEN):
        logger.warning("webhook 签名验证失败")
        raise HTTPException(status_code=403, detail="签名验证失败")

    # 只处理已付款订单
    if order.get("status") != 1:
        return {"ok": True, "message": "订单未付款，跳过"}

    success = handle_order(order, db)
    if success:
        order_no = order.get("out_trade_no", "unknown")
        logger.info(f"✅ webhook 订单处理成功: {order_no}")
        return {"ok": True, "message": "会员已升级"}
    else:
        return {"ok": False, "message": "无法匹配用户"}


# ============================================================
# Admin & Monitoring (protected by simple admin_key)
# ============================================================

_raw_admin = os.environ.get("ADMIN_KEY", "")
if not _raw_admin:
    logger.warning("⚠️ ADMIN_KEY 未设置！管理端点将不可用。请设置环境变量 ADMIN_KEY")
ADMIN_KEY = hashlib.sha256(_raw_admin.encode()).hexdigest()[:16] if _raw_admin else None

def _check_admin(admin_key: str):
    if ADMIN_KEY is None:
        raise HTTPException(status_code=503, detail="管理端点未配置（请设置 ADMIN_KEY 环境变量）")
    if admin_key != ADMIN_KEY:
        raise HTTPException(status_code=403, detail="管理密钥错误")


@app.get("/api/health")
def health():
    return {"status": "ok", "time": datetime.now(timezone.utc).isoformat()}


@app.get("/api/health/detailed")
def detailed_health(admin_key: str, db: Session = Depends(get_db)):
    """详细健康检查（需要 admin_key）"""
    _check_admin(admin_key)
    from monitor import get_daily_stats, get_failure_alerts
    stats = get_daily_stats(db)
    alerts = get_failure_alerts(db, hours=24)
    return {
        "status": "degraded" if alerts else "ok",
        "failure_alerts": alerts,
    }


@app.get("/api/admin/users")
def list_users(admin_key: str, page: int = 1, size: int = 20, db: Session = Depends(get_db)):
    """管理员查看用户列表"""
    _check_admin(admin_key)
    total = db.query(User).count()
    users = db.query(User).order_by(User.created_at.desc()).offset((page-1)*size).limit(size).all()
    return {
        "total": total, "page": page, "size": size,
        "users": [{
            "id": u.id, "email": u.email, "tier": u.tier,
            "is_active": u.is_active,
            "has_config": bool(u.yiban_config),
            "created_at": u.created_at.isoformat(),
        } for u in users]
    }

@app.get("/api/admin/users/{user_id}")
def get_user_detail(user_id: int, admin_key: str, db: Session = Depends(get_db)):
    """管理员查看用户详情（含签到记录）"""
    _check_admin(admin_key)
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在")
    logs = db.query(CheckinLog).filter(CheckinLog.user_id == user_id)\
             .order_by(CheckinLog.created_at.desc()).limit(30).all()
    config = decrypt_config(user.yiban_config)
    return {
        "id": user.id, "email": user.email, "tier": user.tier,
        "is_active": user.is_active, "expires_at": user.expires_at.isoformat() if user.expires_at else None,
        "has_config": bool(user.yiban_config),
        "phone": config.get("phone", "")[:3] + "****" if config.get("phone") else "",
        "school": config.get("school", ""),
        "campus": config.get("campus", ""),
        "created_at": user.created_at.isoformat(),
        "recent_logs": [{"success": l.success, "method": l.method, "message": l.message,
                          "time": l.created_at.isoformat()} for l in logs[:10]],
    }

@app.post("/api/admin/users/{user_id}/toggle")
def toggle_user(user_id: int, admin_key: str, db: Session = Depends(get_db)):
    """管理员启用/禁用用户"""
    _check_admin(admin_key)
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在")
    user.is_active = not user.is_active
    db.commit()
    return {"ok": True, "is_active": user.is_active}

@app.post("/api/admin/notify")
def broadcast_notify(body: NotifyRequest, db: Session = Depends(get_db)):
    """向所有付费用户推送通知"""
    _check_admin(body.admin_key)

    import requests as req
    users = db.query(User).filter(
        User.is_active == True,
        User.push_key != None,
        User.push_key != "",
    ).all()

    paid = [u for u in users if subscription_active(u)]
    sent = 0
    for user in paid:
        try:
            req.post(
                f"https://sctapi.ftqq.com/{user.push_key}.send",
                data={"title": body.title, "desp": body.body},
                timeout=5,
            )
            sent += 1
        except Exception:
            pass

    logger.info(f"📢 通知已推送: {sent}/{len(paid)} 付费用户 — {body.title}")
    return {"ok": True, "sent": sent, "total": len(paid)}
