#
#  Copyright 2024 The InfiniFlow Authors. All Rights Reserved.
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
#

from api.utils.log_utils import initRootLogger
initRootLogger("ragflow_server")

import logging
import os
import signal
import sys
import time
import traceback
from concurrent.futures import ThreadPoolExecutor
import threading
import uuid

from werkzeug.serving import run_simple
from werkzeug.middleware.dispatcher import DispatcherMiddleware
from flask import Flask, jsonify, Response, request
from api import settings
from api.db.runtime_config import RuntimeConfig
from api.db.services.document_service import DocumentService
from api import utils
from api.versions import get_ragflow_version
from rag.utils.redis_conn import RedisDistributedLock

# Global variables
stop_event = threading.Event()
main_app_ready = threading.Event()

# Create a lightweight health check app
health_app = Flask('health_app')

@health_app.route('/healthz', methods=['GET'])
def health_check():
    if main_app_ready.is_set():
        return jsonify({'status': 'ready'}), 200
    else:
        return jsonify({'status': 'starting'}), 200

@health_app.route('/favicon.ico')
def favicon():
    return '', 204

# Function to initialize the main application
def init_main_app():
    try:
        logging.info(r"""
            ____   ___    ______ ______ __               
           / __ \ /   |  / ____// ____// /____  _      __
          / /_/ // /| | / / __ / /_   / // __ \| | /| / /
         / _, _// ___ |/ /_/ // __/  / // /_/ /| |/ |/ / 
        /_/ |_|/_/  |_|\____//_/    /_/ \____/ |__/|__/                             

        """)
        logging.info(f'RAGFlow version: {get_ragflow_version()}')
        logging.info(f'project base: {utils.file_utils.get_project_base_directory()}')
        
        # Initialize configurations
        utils.show_configs()
        settings.init_settings()
        from rag.settings import print_rag_settings
        print_rag_settings()
        
        # Initialize database
        from api.db.db_models import init_database_tables as init_web_db
        from api.db.init_data import init_web_data
        init_web_db()
        init_web_data()
        
        # Initialize runtime config
        RuntimeConfig.init_env()
        RuntimeConfig.init_config(JOB_SERVER_HOST=settings.HOST_IP, HTTP_PORT=settings.HOST_PORT)
        
        # Start the progress update thread
        thread = ThreadPoolExecutor(max_workers=1)
        thread.submit(update_progress)
        
        # Import the main app after initialization
        from api.apps import app as main_flask_app
        
        # Signal that the main app is ready
        main_app_ready.set()
        logging.info("Main application initialization complete")
        
        return main_flask_app
    except Exception as e:
        logging.exception(f"Error initializing main app: {e}")
        stop_event.set()
        time.sleep(1)
        os.kill(os.getpid(), signal.SIGKILL)

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

def signal_handler(sig, frame):
    logging.info("Received interrupt signal, shutting down...")
    stop_event.set()
    time.sleep(1)
    sys.exit(0)

# Create a placeholder for the main app that will be initialized in the background
class LazyLoadMiddleware:
    def __init__(self):
        self.main_app = None
        # Start a thread to initialize the main app
        threading.Thread(target=self._init_app, daemon=True).start()
    
    def _init_app(self):
        self.main_app = init_main_app()
    
    def __call__(self, environ, start_response):
        path = environ.get('PATH_INFO', '')
        
        # Always route health check requests to the health app
        if path == '/healthz' or path == '/favicon.ico':
            return health_app(environ, start_response)
        
        # If the main app is not ready yet, return a loading message
        if not main_app_ready.is_set():
            response = Response(
                "Application is still initializing. Please try again in a few moments.",
                status=503,
                content_type="text/plain"
            )
            return response(environ, start_response)
        
        # Main app is ready, route the request to it
        return self.main_app(environ, start_response)

if __name__ == '__main__':
    # Parse command line arguments
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--version", default=False, help="RAGFlow version", action="store_true"
    )
    parser.add_argument(
        "--debug", default=False, help="debug mode", action="store_true"
    )
    args = parser.parse_args()
    if args.version:
        print(get_ragflow_version())
        sys.exit(0)

    RuntimeConfig.DEBUG = args.debug
    if RuntimeConfig.DEBUG:
        logging.info("run on debug mode")
    
    # Register signal handlers
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)
    
    # Create the middleware application
    application = LazyLoadMiddleware()
    
    # Start the server
    try:
        logging.info("RAGFlow HTTP server starting with immediate health checks...")
        run_simple(
            hostname='0.0.0.0',
            port=8000,
            application=application,
            threaded=True,
            use_reloader=RuntimeConfig.DEBUG,
            use_debugger=RuntimeConfig.DEBUG,
        )
    except Exception:
        traceback.print_exc()
        stop_event.set()
        time.sleep(1)
        os.kill(os.getpid(), signal.SIGKILL)