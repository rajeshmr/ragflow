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
from api.apps import app
import threading
from concurrent.futures import ThreadPoolExecutor
import uuid
from rag.utils.redis_conn import RedisDistributedLock
from flask import jsonify

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

@app.route('/healthz', methods=['GET'])
def health_check():
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

        from api.db.runtime_config import RuntimeConfig
        from api.db.services.document_service import DocumentService
        from api import utils

        from api.db.db_models import init_database_tables as init_web_db
        from api.db.init_data import init_web_data
        
        
        
        from rag.utils.redis_conn import RedisDistributedLock

        init_web_db()
        init_web_data()

        thread = ThreadPoolExecutor(max_workers=1)
        thread.submit(update_progress)
    except Exception:
        traceback.print_exc()
        stop_event.set()
        time.sleep(1)
        os.kill(os.getpid(), signal.SIGKILL)