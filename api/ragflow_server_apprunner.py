from api.utils.log_utils import initRootLogger
initRootLogger("ragflow_server_apprunner")

import logging
import os
import signal
import sys
import time
import traceback
from werkzeug.serving import run_simple
from api.db.runtime_config import RuntimeConfig

import threading
from concurrent.futures import ThreadPoolExecutor
import uuid
from rag.utils.redis_conn import RedisDistributedLock
from flask import jsonify
from flask_session import Session
from flask_login import LoginManager
from api.utils import CustomJSONEncoder, commands
from api.utils.api_utils import server_error_response
from flask import Flask
from flask_cors import CORS

app = Flask(__name__)
CORS(app, supports_credentials=True, max_age=2592000)
app.url_map.strict_slashes = False
app.json_encoder = CustomJSONEncoder
app.errorhandler(Exception)(server_error_response)

## convince for dev and debug
# app.config["LOGIN_DISABLED"] = True
app.config["SESSION_PERMANENT"] = False
app.config["SESSION_TYPE"] = "filesystem"
app.config["MAX_CONTENT_LENGTH"] = int(
    os.environ.get("MAX_CONTENT_LENGTH", 1024 * 1024 * 1024)
)

Session(app)
login_manager = LoginManager()
login_manager.init_app(app)

commands.register_commands(app)


stop_event = threading.Event()

def update_progress():
    lock_value = str(uuid.uuid4())
    redis_lock = RedisDistributedLock("update_progress", lock_value=lock_value, timeout=60)
    logging.info(f"update_progress lock_value: {lock_value}")
    while not stop_event.is_set():
        try:
            if redis_lock.acquire():
                DocumentService.update_progress()
                redis_lock.release()
            stop_event.wait(6)
        except Exception:
            logging.exception("update_progress exception")

def lazy_init():
    from api.db.db_models import init_database_tables as init_web_db
    from api.db.init_data import init_web_data

    init_web_db()
    init_web_data()

    thread = ThreadPoolExecutor(max_workers=1)
    thread.submit(update_progress)

@app.route('/healthz', methods=['GET'])
def health_check():
    return jsonify({'status': 'ok'}), 200

@app.route('/lazy', methods=['GET'])
def lazy():
    lazy_init()
    return jsonify({'status': 'ok'}), 200


@app.route('/favicon.ico')
def favicon():
    return '', 204

if __name__ == '__main__':
    try:
        logging.info("RAGFlow HTTP server start...")
        run_simple(
            hostname='0.0.0.0',
            port=8000,
            application=app,
            threaded=True,
            use_reloader=RuntimeConfig.DEBUG,
            use_debugger=RuntimeConfig.DEBUG,
        )
    except Exception:
        traceback.print_exc()
        stop_event.set()
        time.sleep(1)
        os.kill(os.getpid(), signal.SIGKILL)