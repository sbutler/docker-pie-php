<?php
/**
 * Copyright (c) 2017 University of Illinois Board of Trustees
 * All rights reserved.
 *
 * Developed by:       Technology Services
 *                     University of Illinois at Urbana-Champaign
 *                     https://techservices.illinois.edu/
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * with the Software without restriction, including without limitation the
 * rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
 * sell copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 *     * Redistributions of source code must retain the above copyright notice,
 *       this list of conditions and the following disclaimers.
 *     * Redistributions in binary form must reproduce the above copyright notice,
 *       this list of conditions and the following disclaimers in the
 *       documentation and/or other materials provided with the distribution.
 *     * Neither the names of Technology Services, University of Illinois at
 *       Urbana-Champaign, nor the names of its contributors may be used to
 *       endorse or promote products derived from this Software without specific
 *       prior written permission.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * CONTRIBUTORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS WITH
 * THE SOFTWARE.
 */

# Load this file in order to enable PHP Session handler for DynamoDB

require_once( dirname( __FILE__ ) . '/vendor/autoload.php' );

function pie_dynamodb_register_session_handler() {
    global $pie_dynamodb_session_handler;

    $region = empty( $_SERVER[ 'PIE_DYNAMODB_SESSION_TABLE_REGION' ] )
        ? 'us-east-2'
        : $_SERVER[ 'PIE_DYNAMODB_SESSION_TABLE_REGION' ];
    $name = empty( $_SERVER[ 'PIE_DYNAMODB_SESSION_TABLE_NAME' ] )
        ? 'sessions'
        : $_SERVER[ 'PIE_DYNAMODB_SESSION_TABLE_NAME' ];

    $dynamodb = new \Aws\DynamoDb\DynamoDbClient([
        'version'       => '2012-08-10',
        'region'        => $region,
    ]);
    $pie_dynamodb_session_handler = $dynamodb->registerSessionHandler([
        'table_name'    => $name,
    ]);
}
pie_dynamodb_register_session_handler();
