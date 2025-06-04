<?php

define( 'PIE_POOL_API_KEY', $_SERVER['PIE_POOL_API_KEY'] );

enum HTTPStatusCode : int {
    case Continue = 100;
    case SwitchingProtocols = 101;
    case Processing = 102;
    case EarlyHints = 103;

    case OK = 200;
    case Created = 201;
    case Accepted = 202;
    case NonAuthoritativeInformation = 203;
    case NoContent = 204;
    case ResetContent = 205;
    case PartialContent = 206;

    case MultipleChoices = 300;
    case MovedPermanently = 301;
    case Found = 302;
    case SeeOther = 303;
    case NotModified = 304;
    case UseProxy = 305;
    case TemporaryRedirect = 307;
    case PermanentRedirect = 308;

    case BadRequest = 400;
    case Unauthorized = 401;
    case PaymentRequired = 402;
    case Forbidden = 403;
    case NotFound = 404;
    case MethodNotAllowed = 405;
    case NotAcceptable = 406;
    case ProxyAuthenticationRequired = 407;
    case RequestTimeout = 408;
    case Conflict = 409;
    case Gone = 410;
    case LengthRequired = 411;
    case PreconditionFailed = 412;
    case PayloadTooLarge = 413;
    case URITooLong = 414;
    case UnsupportedMediaType = 415;
    case RangeNotSatisfiable = 416;
    case ExpectationFailed = 417;
    case TooEarly = 425;
    case UpgradeRequired = 426;
    case PreconditionRequired = 428;
    case TooManyRequests = 429;
    case RequestHeaderFieldsTooLarge = 431;

    case InternalServerError = 500;
    case NotImplemented = 501;
    case BadGateway = 502;
    case ServiceUnavailable = 503;
    case GatewayTimneout = 504;
    case HTTPVersionNotSupported = 505;

    public const STATUS_MESSAGES = array(
        100 => 'Continue',
        101 => 'Switching Protocols',
        102 => 'Processing',
        103 => 'Early Hints',

        200 => 'OK',
        201 => 'Created',
        202 => 'Accepted',
        203 => 'Non-Authoritative Information',
        204 => 'No Content',
        205 => 'Reset Content',
        206 => 'Partial Content',

        300 => 'Multiple Choices',
        301 => 'Moved Permanently',
        302 => 'Found',
        303 => 'See Other',
        304 => 'Not Modified',
        305 => 'Use Proxy',
        307 => 'Temporary Redirect',
        308 => 'Permanent Redirect',

        400 => 'Bad Request',
        401 => 'Unauthorized',
        402 => 'Payment Required',
        403 => 'Forbidden',
        404 => 'Not Found',
        405 => 'Method Not Allowed',
        406 => 'Not Acceptable',
        407 => 'Proxy Authentication Required',
        408 => 'Request Timeout',
        409 => 'Conflict',
        410 => 'Gone',
        411 => 'Length Required',
        412 => 'Precondition Failed',
        413 => 'Payload Too Large',
        414 => 'URI Too Long',
        415 => 'Unsupported Media Type',
        416 => 'Range Not Satisfiable',
        417 => 'Expectation Failed',
        425 => 'Too Early',
        426 => 'Upgrade Required',
        428 => 'Precondition Required',
        429 => 'Too Many Requests',
        431 => 'Request Header Fields Too Large',

        500 => 'Internal Server Error',
        501 => 'Not Implemented',
        502 => 'Bad Gateway',
        503 => 'Service Unavailable',
        504 => 'Gateway Timeout',
        505 => 'HTTP Version Not Supported',
    );

    public function getStatusLine() : string {
        return 'HTTP/1.1 ' . $this->value . ' ' . self::STATUS_MESSAGES[$this->value];
    }
}

class HTTPException extends Exception {
    protected HTTPStatusCode $status_code;

    public function __construct( string $message, HTTPStatusCode $status_code = HTTPStatusCode::InternalServerError, ?Exception $previous = null ) {
        parent::__construct( $message, $status_code->value, $previous );
        $this->status_code = $status_code;
    }

    public function __toString() : string {
        return __CLASS__ . ": [{$this->code}]: {$this->message}\n";
    }

    public function getStatusCode() : HTTPStatusCode {
        return $this->status_code;
    }

    public function getHeaders() : array {
        if ($this->isRedirect()) {
            return array(
                'Location: ' . $this->getMessage(),
                $this->status_code->getStatusLine(),
            );
        }

        $result = array(
            'Content-Type: application/json',
            $this->status_code->getStatusLine(),
        );
        if ($this->status_code === HTTPStatusCode::Unauthorized) {
            $result[] = 'WWW-Authenticate: Basic realm="Pool API"';
        }

        return $result;
    }

    public function isRedirect() : bool {
        return $this->status_code->value >= 300 && $this->status_code->value < 400;
    }
}

function api_entrypoint( ?callable $handler = null ) {
    if (is_null( $handler )) {
        $handler = 'handler';
    }

    ob_start();
    try {
        $data = parse_input();
        $result = call_user_func( $handler, $data );

        header( 'Content-Type: application/json' );
        echo json_encode( array(
            'result' => $result,
            'output' => ob_get_clean(),
        ) );
    } catch (HTTPException $ex) {
        foreach ($ex->getHeaders() as $header) {
            header( $header );
        }

        if (!$ex->isRedirect()) {
            echo json_encode( array(
                'error' => array(
                    'message' => $ex->getMessage(),
                    'code'    => $ex->getCode(),
                    'trace'   => $ex->getTraceAsString(),
                ),
                'output' => ob_get_clean(),
            ) );
        }
    } catch (Exception $ex) {
        header( 'HTTP/1.1 500 Internal Server Error' );
        header( 'Content-Type: application/json' );
        echo json_encode( array(
            'error' => array(
                'message' => $ex->getMessage(),
                'code'    => $ex->getCode(),
                'trace'   => $ex->getTraceAsString(),
            ),
            'output' => ob_get_clean(),
        ) );
    }
}

function parse_input() : mixed {
    $data_raw = file_get_contents( 'php://input' );
    if (empty( $data_raw )) {
        $data = array();
    } else {
        $data = json_decode( $data_raw, true );
        if ($data === false) {
            throw new HTTPException( 'Invalid JSON: ' . json_last_error_msg(), HTTPStatusCode::BadRequest );
        }
    }

    return $data;
}

function require_authentication() : bool {
    if (empty( PIE_POOL_API_KEY )) {
        throw new HTTPException( 'API key not set', HTTPStatusCode::InternalServerError );
    } else if (empty( $_SERVER['PHP_AUTH_PW'] )) {
        throw new HTTPException( 'No Basic authentication set', HTTPStatusCode::Unauthorized );
    } else if ($_SERVER['PHP_AUTH_PW'] !== PIE_POOL_API_KEY) {
        throw new HTTPException( 'Basic authentication failure', HTTPStatusCode::Forbidden );
    }

    return true;
}
