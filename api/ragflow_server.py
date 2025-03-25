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

# from beartype import BeartypeConf
# from beartype.claw import beartype_all  # <-- you didn't sign up for this
# beartype_all(conf=BeartypeConf(violation_type=UserWarning))    # <-- emit warnings from all code

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

from mangum import Mangum
from api import settings
from api.apps import app
from api.db.runtime_config import RuntimeConfig
from api.db.services.document_service import DocumentService
from api import utils
from aws_lambda_powertools import Logger
from aws_lambda_powertools.event_handler import APIGatewayRestResolver
from aws_lambda_powertools.utilities.typing import LambdaContext

from api.db.db_models import init_database_tables as init_web_db
from api.db.init_data import init_web_data
from api.versions import get_ragflow_version
from api.utils import show_configs
from rag.settings import print_rag_settings
from rag.utils.redis_conn import RedisDistributedLock

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

def signal_handler(sig, frame):
    logging.info("Received interrupt signal, shutting down...")
    stop_event.set()
    time.sleep(1)
    sys.exit(0)

# Initialize Lambda handler
handler = Mangum(app)
logger = Logger()

def init_app():
    """Initialize the application"""
    logging.info(f'RAGFlow version: {get_ragflow_version()}')
    logging.info(f'project base: {utils.file_utils.get_project_base_directory()}')
    show_configs()
    settings.init_settings()
    print_rag_settings()

    # init db
    init_web_db()
    init_web_data()

    RuntimeConfig.DEBUG = False
    RuntimeConfig.init_env()
    RuntimeConfig.init_config(
        JOB_SERVER_HOST=settings.HOST_IP,
        HTTP_PORT=settings.HOST_PORT
    )

    # Start progress update in a background thread
    thread = ThreadPoolExecutor(max_workers=1)
    thread.submit(update_progress)

@logger.inject_lambda_context
def lambda_handler(event: dict, context: LambdaContext) -> dict:
    """AWS Lambda handler"""
    try:
        # Initialize app on cold start
        init_app()
        return handler(event, context)
    except Exception as e:
        logger.exception("Error handling request")
        return {
            "statusCode": 500,
            "body": str(e)
        }

if __name__ == '__main__':
    # For local development
    init_app()
    app.run(host=settings.HOST_IP, port=settings.HOST_PORT, debug=True)
