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
import os
import os.path
import logging
from logging.handlers import RotatingFileHandler

initialized_root_logger = False

def get_project_base_directory():
    PROJECT_BASE = os.path.abspath(
        os.path.join(
            os.path.dirname(os.path.realpath(__file__)),
            os.pardir,
            os.pardir,
        )
    )
    return PROJECT_BASE

def initRootLogger(logfile_basename: str, log_format: str = "%(asctime)-15s %(levelname)-8s %(process)d %(message)s"):
    global initialized_root_logger
    if initialized_root_logger:
        return
    initialized_root_logger = True

    logger = logging.getLogger()
    logger.handlers.clear()
    
    # Configure only StreamHandler for CloudWatch integration
    # All logs will go to stdout which CloudWatch captures automatically
    formatter = logging.Formatter(log_format)
    
    # Create a single StreamHandler for stdout
    stream_handler = logging.StreamHandler()
    stream_handler.setFormatter(formatter)
    logger.addHandler(stream_handler)

    logging.captureWarnings(True)

    LOG_LEVELS = os.environ.get("LOG_LEVELS", "")
    pkg_levels = {}
    for pkg_name_level in LOG_LEVELS.split(","):
        terms = pkg_name_level.split("=")
        if len(terms)!= 2:
            continue
        pkg_name, pkg_level = terms[0], terms[1]
        pkg_name = pkg_name.strip()
        pkg_level = logging.getLevelName(pkg_level.strip().upper())
        if not isinstance(pkg_level, int):
            pkg_level = logging.INFO
        pkg_levels[pkg_name] = logging.getLevelName(pkg_level)

    for pkg_name in ['peewee', 'pdfminer']:
        if pkg_name not in pkg_levels:
            pkg_levels[pkg_name] = logging.getLevelName(logging.WARNING)
    if 'root' not in pkg_levels:
        pkg_levels['root'] = logging.getLevelName(logging.INFO)

    for pkg_name, pkg_level in pkg_levels.items():
        pkg_logger = logging.getLogger(pkg_name)
        pkg_logger.setLevel(pkg_level)

    msg = f"{logfile_basename} log levels: {pkg_levels} (logging to stdout for CloudWatch)"
    logger.info(msg)