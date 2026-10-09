<?php
// Task-owned basic RFC 4791 CalDAV server for Plainpost calendar acceptance.
//
// This is the documented minimal sabre/dav CalDAV server layout
// (https://sabre.io/dav/caldav/): principals, calendar root, authentication,
// ACL and the CalDAV plugin. It deliberately registers neither
// Sabre\DAV\Sync\Plugin (RFC 6578 sync-collection / sync-token) nor
// Sabre\CalDAV\Schedule\Plugin (RFC 6638 scheduling), so clients must use
// calendar-query/multiget, ETags and conditional writes only.
//
// It runs on the sabre/dav 4.7.0 copy vendored in the pinned Baikal 0.10.1
// image, replacing that image's dav.php in a separate, task-owned container.
date_default_timezone_set('UTC');
require '/var/www/baikal/vendor/autoload.php';

$pdo = new PDO('sqlite:/var/www/baikal/Specific/db/db.sqlite');
$pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
set_error_handler(function ($severity, $message, $file, $line) {
    throw new ErrorException($message, 0, $severity, $file, $line);
});

$authentication = new Sabre\DAV\Auth\Backend\BasicCallBack(function ($username, $password) use ($pdo) {
    $statement = $pdo->prepare('SELECT digesta1 FROM users WHERE username = ?');
    $statement->execute([$username]);
    $digest = $statement->fetchColumn();
    return is_string($digest) && hash_equals($digest, md5($username . ':BaikalDAV:' . $password));
});
$principals = new Sabre\DAVACL\PrincipalBackend\PDO($pdo);
$calendars = new Sabre\CalDAV\Backend\PDO($pdo);

$server = new Sabre\DAV\Server([
    new Sabre\CalDAV\Principal\Collection($principals),
    new Sabre\CalDAV\CalendarRoot($principals, $calendars),
]);
$server->setBaseUri('/dav.php/');
$server->addPlugin(new Sabre\DAV\Auth\Plugin($authentication));
$server->addPlugin(new Sabre\DAVACL\Plugin());
$server->addPlugin(new Sabre\CalDAV\Plugin());
$server->exec();
