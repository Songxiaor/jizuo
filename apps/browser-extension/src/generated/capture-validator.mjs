/* eslint-disable */
// Generated from contracts/capture-envelope-v1.schema.json. Do not edit by hand.
import * as __ajvFormats from "ajv-formats/dist/formats.js";
"use strict";
export const validate = validate20;
export default validate20;
const schema31 = {"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"https://syc.local/linkdigest/capture-envelope-v1.schema.json","title":"LinkDigest V0.1 Capture Contract","description":"Language-neutral Native Messaging contract. Objects accept unknown optional fields for forward compatibility; required fields and semantic invariants remain enforced by both runtimes.","type":"object","required":["version","requestId","createdAt","source","capture","evidence"],"additionalProperties":true,"properties":{"version":{"const":1},"requestId":{"type":"string","minLength":1,"maxLength":128},"createdAt":{"type":"string","format":"date-time"},"idempotencyKey":{"type":"string","minLength":1,"maxLength":256},"source":{"type":"object","required":["kind","url","title","platform"],"additionalProperties":true,"properties":{"kind":{"const":"browser_capture"},"url":{"type":"string","format":"uri","maxLength":8192,"pattern":"^https?://"},"title":{"type":["string","null"],"maxLength":1024},"platform":{"type":"string","enum":["generic","x","youtube","wechat","xiaohongshu","douyin","bilibili"]}}},"capture":{"type":"object","required":["method","text","characterCount","completeness","capturedAt"],"additionalProperties":true,"properties":{"method":{"type":"string","enum":["rendered_dom","selection"]},"text":{"type":"string","minLength":1,"maxLength":2000000},"characterCount":{"type":"integer","minimum":1,"maximum":2000000},"completeness":{"type":"string","enum":["full_article","visible_only","selection_only","unknown"]},"capturedAt":{"type":"string","format":"date-time"}}},"evidence":{"type":"object","required":["sourceLabel","usedCookie"],"additionalProperties":true,"properties":{"sourceLabel":{"type":"string","minLength":1,"maxLength":128},"usedCookie":{"const":false}}}},"$defs":{"AppError":{"type":"object","required":["version","requestId","createdAt","category","code","retryable","action"],"additionalProperties":true,"properties":{"version":{"const":1},"requestId":{"type":"string","minLength":1,"maxLength":128},"createdAt":{"type":"string","format":"date-time"},"category":{"type":"string","enum":["protocol","permission","network","extraction","storage","unknown"]},"code":{"type":"string","pattern":"^[A-Z][A-Z0-9_]{2,63}$"},"retryable":{"type":"boolean"},"action":{"type":"string","enum":["retry","open_app","open_install_guide","open_in_browser","grant_permission","upgrade_app","none"]},"safeDetail":{"type":"string","maxLength":2000}}},"NativeResponse":{"oneOf":[{"type":"object","required":["kind","version","requestId","characterCount"],"additionalProperties":true,"properties":{"kind":{"const":"taskAccepted"},"version":{"const":1},"requestId":{"type":"string"},"characterCount":{"type":"integer"}}},{"type":"object","required":["kind","error"],"additionalProperties":true,"properties":{"kind":{"const":"error"},"error":{"$ref":"#/$defs/AppError"}}}]}},"x-semantic-invariants":["capture.characterCount equals the Unicode code point count of capture.text (Swift scalar count; TypeScript [...text].length)","capture.text and all URL/title fields are never written to ordinary logs","Native Messaging framing limit is 4 MiB bytes; text limit is 2,000,000 Unicode scalars"]};
const func1 = (value) => [...value].length;
const formats0 = __ajvFormats.fullFormats["date-time"];
const formats2 = __ajvFormats.fullFormats.uri;
const pattern4 = new RegExp("^https?://", "u");

function validate20(data, {instancePath="", parentData, parentDataProperty, rootData=data, dynamicAnchors={}}={}){
/*# sourceURL="https://syc.local/linkdigest/capture-envelope-v1.schema.json" */;
let vErrors = null;
let errors = 0;
const evaluated0 = validate20.evaluated;
if(evaluated0.dynamicProps){
evaluated0.props = undefined;
}
if(evaluated0.dynamicItems){
evaluated0.items = undefined;
}
if(data && typeof data == "object" && !Array.isArray(data)){
if(data.version === undefined){
const err0 = {instancePath,schemaPath:"#/required",keyword:"required",params:{missingProperty: "version"},message:"must have required property '"+"version"+"'"};
if(vErrors === null){
vErrors = [err0];
}
else {
vErrors.push(err0);
}
errors++;
}
if(data.requestId === undefined){
const err1 = {instancePath,schemaPath:"#/required",keyword:"required",params:{missingProperty: "requestId"},message:"must have required property '"+"requestId"+"'"};
if(vErrors === null){
vErrors = [err1];
}
else {
vErrors.push(err1);
}
errors++;
}
if(data.createdAt === undefined){
const err2 = {instancePath,schemaPath:"#/required",keyword:"required",params:{missingProperty: "createdAt"},message:"must have required property '"+"createdAt"+"'"};
if(vErrors === null){
vErrors = [err2];
}
else {
vErrors.push(err2);
}
errors++;
}
if(data.source === undefined){
const err3 = {instancePath,schemaPath:"#/required",keyword:"required",params:{missingProperty: "source"},message:"must have required property '"+"source"+"'"};
if(vErrors === null){
vErrors = [err3];
}
else {
vErrors.push(err3);
}
errors++;
}
if(data.capture === undefined){
const err4 = {instancePath,schemaPath:"#/required",keyword:"required",params:{missingProperty: "capture"},message:"must have required property '"+"capture"+"'"};
if(vErrors === null){
vErrors = [err4];
}
else {
vErrors.push(err4);
}
errors++;
}
if(data.evidence === undefined){
const err5 = {instancePath,schemaPath:"#/required",keyword:"required",params:{missingProperty: "evidence"},message:"must have required property '"+"evidence"+"'"};
if(vErrors === null){
vErrors = [err5];
}
else {
vErrors.push(err5);
}
errors++;
}
if(data.version !== undefined){
if(1 !== data.version){
const err6 = {instancePath:instancePath+"/version",schemaPath:"#/properties/version/const",keyword:"const",params:{allowedValue: 1},message:"must be equal to constant"};
if(vErrors === null){
vErrors = [err6];
}
else {
vErrors.push(err6);
}
errors++;
}
}
if(data.requestId !== undefined){
let data1 = data.requestId;
if(typeof data1 === "string"){
if(func1(data1) > 128){
const err7 = {instancePath:instancePath+"/requestId",schemaPath:"#/properties/requestId/maxLength",keyword:"maxLength",params:{limit: 128},message:"must NOT have more than 128 characters"};
if(vErrors === null){
vErrors = [err7];
}
else {
vErrors.push(err7);
}
errors++;
}
if(func1(data1) < 1){
const err8 = {instancePath:instancePath+"/requestId",schemaPath:"#/properties/requestId/minLength",keyword:"minLength",params:{limit: 1},message:"must NOT have fewer than 1 characters"};
if(vErrors === null){
vErrors = [err8];
}
else {
vErrors.push(err8);
}
errors++;
}
}
else {
const err9 = {instancePath:instancePath+"/requestId",schemaPath:"#/properties/requestId/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err9];
}
else {
vErrors.push(err9);
}
errors++;
}
}
if(data.createdAt !== undefined){
let data2 = data.createdAt;
if(typeof data2 === "string"){
if(!(formats0.validate(data2))){
const err10 = {instancePath:instancePath+"/createdAt",schemaPath:"#/properties/createdAt/format",keyword:"format",params:{format: "date-time"},message:"must match format \""+"date-time"+"\""};
if(vErrors === null){
vErrors = [err10];
}
else {
vErrors.push(err10);
}
errors++;
}
}
else {
const err11 = {instancePath:instancePath+"/createdAt",schemaPath:"#/properties/createdAt/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err11];
}
else {
vErrors.push(err11);
}
errors++;
}
}
if(data.idempotencyKey !== undefined){
let data3 = data.idempotencyKey;
if(typeof data3 === "string"){
if(func1(data3) > 256){
const err12 = {instancePath:instancePath+"/idempotencyKey",schemaPath:"#/properties/idempotencyKey/maxLength",keyword:"maxLength",params:{limit: 256},message:"must NOT have more than 256 characters"};
if(vErrors === null){
vErrors = [err12];
}
else {
vErrors.push(err12);
}
errors++;
}
if(func1(data3) < 1){
const err13 = {instancePath:instancePath+"/idempotencyKey",schemaPath:"#/properties/idempotencyKey/minLength",keyword:"minLength",params:{limit: 1},message:"must NOT have fewer than 1 characters"};
if(vErrors === null){
vErrors = [err13];
}
else {
vErrors.push(err13);
}
errors++;
}
}
else {
const err14 = {instancePath:instancePath+"/idempotencyKey",schemaPath:"#/properties/idempotencyKey/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err14];
}
else {
vErrors.push(err14);
}
errors++;
}
}
if(data.source !== undefined){
let data4 = data.source;
if(data4 && typeof data4 == "object" && !Array.isArray(data4)){
if(data4.kind === undefined){
const err15 = {instancePath:instancePath+"/source",schemaPath:"#/properties/source/required",keyword:"required",params:{missingProperty: "kind"},message:"must have required property '"+"kind"+"'"};
if(vErrors === null){
vErrors = [err15];
}
else {
vErrors.push(err15);
}
errors++;
}
if(data4.url === undefined){
const err16 = {instancePath:instancePath+"/source",schemaPath:"#/properties/source/required",keyword:"required",params:{missingProperty: "url"},message:"must have required property '"+"url"+"'"};
if(vErrors === null){
vErrors = [err16];
}
else {
vErrors.push(err16);
}
errors++;
}
if(data4.title === undefined){
const err17 = {instancePath:instancePath+"/source",schemaPath:"#/properties/source/required",keyword:"required",params:{missingProperty: "title"},message:"must have required property '"+"title"+"'"};
if(vErrors === null){
vErrors = [err17];
}
else {
vErrors.push(err17);
}
errors++;
}
if(data4.platform === undefined){
const err18 = {instancePath:instancePath+"/source",schemaPath:"#/properties/source/required",keyword:"required",params:{missingProperty: "platform"},message:"must have required property '"+"platform"+"'"};
if(vErrors === null){
vErrors = [err18];
}
else {
vErrors.push(err18);
}
errors++;
}
if(data4.kind !== undefined){
if("browser_capture" !== data4.kind){
const err19 = {instancePath:instancePath+"/source/kind",schemaPath:"#/properties/source/properties/kind/const",keyword:"const",params:{allowedValue: "browser_capture"},message:"must be equal to constant"};
if(vErrors === null){
vErrors = [err19];
}
else {
vErrors.push(err19);
}
errors++;
}
}
if(data4.url !== undefined){
let data6 = data4.url;
if(typeof data6 === "string"){
if(func1(data6) > 8192){
const err20 = {instancePath:instancePath+"/source/url",schemaPath:"#/properties/source/properties/url/maxLength",keyword:"maxLength",params:{limit: 8192},message:"must NOT have more than 8192 characters"};
if(vErrors === null){
vErrors = [err20];
}
else {
vErrors.push(err20);
}
errors++;
}
if(!pattern4.test(data6)){
const err21 = {instancePath:instancePath+"/source/url",schemaPath:"#/properties/source/properties/url/pattern",keyword:"pattern",params:{pattern: "^https?://"},message:"must match pattern \""+"^https?://"+"\""};
if(vErrors === null){
vErrors = [err21];
}
else {
vErrors.push(err21);
}
errors++;
}
if(!(formats2(data6))){
const err22 = {instancePath:instancePath+"/source/url",schemaPath:"#/properties/source/properties/url/format",keyword:"format",params:{format: "uri"},message:"must match format \""+"uri"+"\""};
if(vErrors === null){
vErrors = [err22];
}
else {
vErrors.push(err22);
}
errors++;
}
}
else {
const err23 = {instancePath:instancePath+"/source/url",schemaPath:"#/properties/source/properties/url/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err23];
}
else {
vErrors.push(err23);
}
errors++;
}
}
if(data4.title !== undefined){
let data7 = data4.title;
if((typeof data7 !== "string") && (data7 !== null)){
const err24 = {instancePath:instancePath+"/source/title",schemaPath:"#/properties/source/properties/title/type",keyword:"type",params:{type: schema31.properties.source.properties.title.type},message:"must be string,null"};
if(vErrors === null){
vErrors = [err24];
}
else {
vErrors.push(err24);
}
errors++;
}
if(typeof data7 === "string"){
if(func1(data7) > 1024){
const err25 = {instancePath:instancePath+"/source/title",schemaPath:"#/properties/source/properties/title/maxLength",keyword:"maxLength",params:{limit: 1024},message:"must NOT have more than 1024 characters"};
if(vErrors === null){
vErrors = [err25];
}
else {
vErrors.push(err25);
}
errors++;
}
}
}
if(data4.platform !== undefined){
let data8 = data4.platform;
if(typeof data8 !== "string"){
const err26 = {instancePath:instancePath+"/source/platform",schemaPath:"#/properties/source/properties/platform/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err26];
}
else {
vErrors.push(err26);
}
errors++;
}
if(!(((((((data8 === "generic") || (data8 === "x")) || (data8 === "youtube")) || (data8 === "wechat")) || (data8 === "xiaohongshu")) || (data8 === "douyin")) || (data8 === "bilibili"))){
const err27 = {instancePath:instancePath+"/source/platform",schemaPath:"#/properties/source/properties/platform/enum",keyword:"enum",params:{allowedValues: schema31.properties.source.properties.platform.enum},message:"must be equal to one of the allowed values"};
if(vErrors === null){
vErrors = [err27];
}
else {
vErrors.push(err27);
}
errors++;
}
}
}
else {
const err28 = {instancePath:instancePath+"/source",schemaPath:"#/properties/source/type",keyword:"type",params:{type: "object"},message:"must be object"};
if(vErrors === null){
vErrors = [err28];
}
else {
vErrors.push(err28);
}
errors++;
}
}
if(data.capture !== undefined){
let data9 = data.capture;
if(data9 && typeof data9 == "object" && !Array.isArray(data9)){
if(data9.method === undefined){
const err29 = {instancePath:instancePath+"/capture",schemaPath:"#/properties/capture/required",keyword:"required",params:{missingProperty: "method"},message:"must have required property '"+"method"+"'"};
if(vErrors === null){
vErrors = [err29];
}
else {
vErrors.push(err29);
}
errors++;
}
if(data9.text === undefined){
const err30 = {instancePath:instancePath+"/capture",schemaPath:"#/properties/capture/required",keyword:"required",params:{missingProperty: "text"},message:"must have required property '"+"text"+"'"};
if(vErrors === null){
vErrors = [err30];
}
else {
vErrors.push(err30);
}
errors++;
}
if(data9.characterCount === undefined){
const err31 = {instancePath:instancePath+"/capture",schemaPath:"#/properties/capture/required",keyword:"required",params:{missingProperty: "characterCount"},message:"must have required property '"+"characterCount"+"'"};
if(vErrors === null){
vErrors = [err31];
}
else {
vErrors.push(err31);
}
errors++;
}
if(data9.completeness === undefined){
const err32 = {instancePath:instancePath+"/capture",schemaPath:"#/properties/capture/required",keyword:"required",params:{missingProperty: "completeness"},message:"must have required property '"+"completeness"+"'"};
if(vErrors === null){
vErrors = [err32];
}
else {
vErrors.push(err32);
}
errors++;
}
if(data9.capturedAt === undefined){
const err33 = {instancePath:instancePath+"/capture",schemaPath:"#/properties/capture/required",keyword:"required",params:{missingProperty: "capturedAt"},message:"must have required property '"+"capturedAt"+"'"};
if(vErrors === null){
vErrors = [err33];
}
else {
vErrors.push(err33);
}
errors++;
}
if(data9.method !== undefined){
let data10 = data9.method;
if(typeof data10 !== "string"){
const err34 = {instancePath:instancePath+"/capture/method",schemaPath:"#/properties/capture/properties/method/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err34];
}
else {
vErrors.push(err34);
}
errors++;
}
if(!((data10 === "rendered_dom") || (data10 === "selection"))){
const err35 = {instancePath:instancePath+"/capture/method",schemaPath:"#/properties/capture/properties/method/enum",keyword:"enum",params:{allowedValues: schema31.properties.capture.properties.method.enum},message:"must be equal to one of the allowed values"};
if(vErrors === null){
vErrors = [err35];
}
else {
vErrors.push(err35);
}
errors++;
}
}
if(data9.text !== undefined){
let data11 = data9.text;
if(typeof data11 === "string"){
if(func1(data11) > 2000000){
const err36 = {instancePath:instancePath+"/capture/text",schemaPath:"#/properties/capture/properties/text/maxLength",keyword:"maxLength",params:{limit: 2000000},message:"must NOT have more than 2000000 characters"};
if(vErrors === null){
vErrors = [err36];
}
else {
vErrors.push(err36);
}
errors++;
}
if(func1(data11) < 1){
const err37 = {instancePath:instancePath+"/capture/text",schemaPath:"#/properties/capture/properties/text/minLength",keyword:"minLength",params:{limit: 1},message:"must NOT have fewer than 1 characters"};
if(vErrors === null){
vErrors = [err37];
}
else {
vErrors.push(err37);
}
errors++;
}
}
else {
const err38 = {instancePath:instancePath+"/capture/text",schemaPath:"#/properties/capture/properties/text/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err38];
}
else {
vErrors.push(err38);
}
errors++;
}
}
if(data9.characterCount !== undefined){
let data12 = data9.characterCount;
if(!((typeof data12 == "number") && (!(data12 % 1) && !isNaN(data12)))){
const err39 = {instancePath:instancePath+"/capture/characterCount",schemaPath:"#/properties/capture/properties/characterCount/type",keyword:"type",params:{type: "integer"},message:"must be integer"};
if(vErrors === null){
vErrors = [err39];
}
else {
vErrors.push(err39);
}
errors++;
}
if(typeof data12 == "number"){
if(data12 > 2000000 || isNaN(data12)){
const err40 = {instancePath:instancePath+"/capture/characterCount",schemaPath:"#/properties/capture/properties/characterCount/maximum",keyword:"maximum",params:{comparison: "<=", limit: 2000000},message:"must be <= 2000000"};
if(vErrors === null){
vErrors = [err40];
}
else {
vErrors.push(err40);
}
errors++;
}
if(data12 < 1 || isNaN(data12)){
const err41 = {instancePath:instancePath+"/capture/characterCount",schemaPath:"#/properties/capture/properties/characterCount/minimum",keyword:"minimum",params:{comparison: ">=", limit: 1},message:"must be >= 1"};
if(vErrors === null){
vErrors = [err41];
}
else {
vErrors.push(err41);
}
errors++;
}
}
}
if(data9.completeness !== undefined){
let data13 = data9.completeness;
if(typeof data13 !== "string"){
const err42 = {instancePath:instancePath+"/capture/completeness",schemaPath:"#/properties/capture/properties/completeness/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err42];
}
else {
vErrors.push(err42);
}
errors++;
}
if(!((((data13 === "full_article") || (data13 === "visible_only")) || (data13 === "selection_only")) || (data13 === "unknown"))){
const err43 = {instancePath:instancePath+"/capture/completeness",schemaPath:"#/properties/capture/properties/completeness/enum",keyword:"enum",params:{allowedValues: schema31.properties.capture.properties.completeness.enum},message:"must be equal to one of the allowed values"};
if(vErrors === null){
vErrors = [err43];
}
else {
vErrors.push(err43);
}
errors++;
}
}
if(data9.capturedAt !== undefined){
let data14 = data9.capturedAt;
if(typeof data14 === "string"){
if(!(formats0.validate(data14))){
const err44 = {instancePath:instancePath+"/capture/capturedAt",schemaPath:"#/properties/capture/properties/capturedAt/format",keyword:"format",params:{format: "date-time"},message:"must match format \""+"date-time"+"\""};
if(vErrors === null){
vErrors = [err44];
}
else {
vErrors.push(err44);
}
errors++;
}
}
else {
const err45 = {instancePath:instancePath+"/capture/capturedAt",schemaPath:"#/properties/capture/properties/capturedAt/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err45];
}
else {
vErrors.push(err45);
}
errors++;
}
}
}
else {
const err46 = {instancePath:instancePath+"/capture",schemaPath:"#/properties/capture/type",keyword:"type",params:{type: "object"},message:"must be object"};
if(vErrors === null){
vErrors = [err46];
}
else {
vErrors.push(err46);
}
errors++;
}
}
if(data.evidence !== undefined){
let data15 = data.evidence;
if(data15 && typeof data15 == "object" && !Array.isArray(data15)){
if(data15.sourceLabel === undefined){
const err47 = {instancePath:instancePath+"/evidence",schemaPath:"#/properties/evidence/required",keyword:"required",params:{missingProperty: "sourceLabel"},message:"must have required property '"+"sourceLabel"+"'"};
if(vErrors === null){
vErrors = [err47];
}
else {
vErrors.push(err47);
}
errors++;
}
if(data15.usedCookie === undefined){
const err48 = {instancePath:instancePath+"/evidence",schemaPath:"#/properties/evidence/required",keyword:"required",params:{missingProperty: "usedCookie"},message:"must have required property '"+"usedCookie"+"'"};
if(vErrors === null){
vErrors = [err48];
}
else {
vErrors.push(err48);
}
errors++;
}
if(data15.sourceLabel !== undefined){
let data16 = data15.sourceLabel;
if(typeof data16 === "string"){
if(func1(data16) > 128){
const err49 = {instancePath:instancePath+"/evidence/sourceLabel",schemaPath:"#/properties/evidence/properties/sourceLabel/maxLength",keyword:"maxLength",params:{limit: 128},message:"must NOT have more than 128 characters"};
if(vErrors === null){
vErrors = [err49];
}
else {
vErrors.push(err49);
}
errors++;
}
if(func1(data16) < 1){
const err50 = {instancePath:instancePath+"/evidence/sourceLabel",schemaPath:"#/properties/evidence/properties/sourceLabel/minLength",keyword:"minLength",params:{limit: 1},message:"must NOT have fewer than 1 characters"};
if(vErrors === null){
vErrors = [err50];
}
else {
vErrors.push(err50);
}
errors++;
}
}
else {
const err51 = {instancePath:instancePath+"/evidence/sourceLabel",schemaPath:"#/properties/evidence/properties/sourceLabel/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err51];
}
else {
vErrors.push(err51);
}
errors++;
}
}
if(data15.usedCookie !== undefined){
if(false !== data15.usedCookie){
const err52 = {instancePath:instancePath+"/evidence/usedCookie",schemaPath:"#/properties/evidence/properties/usedCookie/const",keyword:"const",params:{allowedValue: false},message:"must be equal to constant"};
if(vErrors === null){
vErrors = [err52];
}
else {
vErrors.push(err52);
}
errors++;
}
}
}
else {
const err53 = {instancePath:instancePath+"/evidence",schemaPath:"#/properties/evidence/type",keyword:"type",params:{type: "object"},message:"must be object"};
if(vErrors === null){
vErrors = [err53];
}
else {
vErrors.push(err53);
}
errors++;
}
}
}
else {
const err54 = {instancePath,schemaPath:"#/type",keyword:"type",params:{type: "object"},message:"must be object"};
if(vErrors === null){
vErrors = [err54];
}
else {
vErrors.push(err54);
}
errors++;
}
validate20.errors = vErrors;
return errors === 0;
}
validate20.evaluated = {"props":true,"dynamicProps":false,"dynamicItems":false};

