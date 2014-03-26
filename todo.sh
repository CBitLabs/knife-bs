#!/bin/bash

egrep -r "(TODO|REVIEW|FUTURE)" . -A 4 | less
