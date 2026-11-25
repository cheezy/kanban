/// What the app can ask the server for: one method per `/api/me` and `/oauth`
/// operation in the contract.
///
/// View models depend on `any StrideAPI`, so the app gives them the client from
/// `StrideClient`, and previews and tests give them `FixtureAPI().client`.
///
/// The API adds values to its enums over time, so most are read as a struct of
/// two: `value1` is the case this version knows, or nil, and `value2` is the
/// text the server sent.
///
/// Never log or show a `ClientError`, an input or an output: its description
/// holds the request and the response, with any token in them.
public protocol StrideAPI: APIProtocol {}

extension Client: StrideAPI {}
