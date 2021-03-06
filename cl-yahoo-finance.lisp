;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;; cl-yahoo-finance
;;;;
;;;; Obtains Yahoo's finance information and presents the information
;;;; as a hash table.
;;;;
;;;; Maintainer: Paul Nathan
;;;; Licence LLGPL
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;; developer notes.
;;
;; TODO: Find the profit % and numbers for the most recent quarter and
;; return that in read-current-company-info
;;
;; TODO: Normalize interfaces


(defpackage :cl-yahoo-finance
  (:use :common-lisp)
  (:export
   :read-current-options
   :read-current-data                   ; this may not work
   :read-current-data-from-csv          ; this is the fallback
   :read-historical-data
   :read-historical-splits
   :read-current-company-info
   :*proxy*
   :with-proxy))
(in-package :cl-yahoo-finance)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Proxy Variable

(defparameter *proxy*
  nil
  "HTTP proxy: Takes nil, address as string, or list containing
address as string and port as integer")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(defparameter *debug*
  nil
  "Debugging parameter. Don't set it unless you're digging around")


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Misc utility routines

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(defun concat-list(seq)
  "Concatenates a list of strings"
  (reduce #'(lambda (r s)
              (concatenate 'string r s))
          seq))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; less typing
(defun to-s (thing)
  "Converts `thing` to a string using FORMAT"
  (format nil "~a" thing))
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(defun getassoc (item alist &key key (test #'eql) )
  (cdr (assoc item alist :key key :test test)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(defun strcat (&rest strings)
  (apply 'concatenate 'string strings))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Convert

(defun convert-from-column-strings (dataset)
  ;; first row indicates the keys
  (let ((keys (mapcar
               #'(lambda (key)
                   ;; TODO: factor this out.
                   (intern
                    (substitute-if
                     #\-
                     #'(lambda (c)
                         (alexandria:switch
                             (c :test #'char=)
                           (#\Space t)))
                     (string-upcase key))
                    'keyword))
               (car dataset)))
        (data (cdr dataset)))
    (mapcar
     #'(lambda (row)
         (alexandria:alist-hash-table (pairlis keys row)))
     data)))

(defun convert-stringy-table-to-keyword (hash-table)
  "Returns a new hash table with keywords as the keys instead of
strings"
  (let ((keys (alexandria:hash-table-keys hash-table))
        (new-table (make-hash-table)))
    (loop for key in keys
         do
         (setf (gethash (intern (string-upcase key) 'keyword) new-table)
               (gethash key hash-table)))
    new-table))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(defun enquote-string (string)
  "Surround `string` with double-quotes, suitable for passing to other
systems."
  (strcat
   "\"" string "\""))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(defun request-yql-info (table symbol-list)
  "Calls out to the YQL online API to get info on the list of stock
symbols"
  (let ((quoted-symbols
         (format nil "~{~A~^,~}"  ;join
                 (mapcar #'enquote-string
                         symbol-list))))
;;http://query.yahooapis.com/v1/public/yql
;; ?q=select%20*%20from%20yahoo.finance.quotes%20where%20symbol%20in%20(%22YHOO%22%2C%22AAPL%22%2C%22GOOG%22%2C%22MSFT%22)&
;; diagnostics=true
;; &env=store%3A%2F%2Fdatatables.org%2Falltableswithkeys
    (babel:octets-to-string
     (drakma:http-request
      "http://query.yahooapis.com/v1/public/yql"
      :parameters
      (list*
       (cons "q" (strcat
                  "select * from "
                  table
                  " where symbol in ("
                  quoted-symbols ")"))
       '(("format" . "json")
         ("diagnostics" . "true")
         ("env" . "store://datatables.org/alltableswithkeys")))
      :proxy *proxy*))))


(defun request-yql-options-info (symbol-list)
  (request-yql-info "yahoo.finance.options" symbol-list))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(defun request-yql-stock-info (symbol-list)
  (request-yql-info "yahoo.finance.quotes" symbol-list))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(defun request-yql-quant-info (symbol-list)
  (request-yql-info "yahoo.finance.quant" symbol-list))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(defun yason-stock-options-parse (quote-string)
  "Reads a string assumed to be Yahoo Finance options tables.

Returns a list of hash tables. Each hash table has keys \"symbol\"
  and \"option\"

symbol points out to the symbol desired;
option points out a a hash table with the following keys

openInt, vol, ask, bid, changeDir, change, lastPrice, strikePrice,
type, symbol"

  (let ((return-table
         (alexandria:ensure-list
          (gethash
           "optionsChain"
           (gethash
            "results"
            (gethash
             "query"
             (yason:parse quote-string)))))))
    ;; symbol => some-symbol
    ;; option => ( hash-table-option ... )

    ;; fixup the top-level keys
    (let ((fixed-up-table-list
           (mapcar
            #'convert-stringy-table-to-keyword
            return-table)))

      (mapcar
       #'(lambda (fixed-up-table)
           ;; fixup the :option list
           (let ((chain
                  (gethash :option fixed-up-table)))
             (setf (gethash :option fixed-up-table)
                   (mapcar
                    #'convert-stringy-table-to-keyword
                    chain))
             fixed-up-table))

       fixed-up-table-list))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(defun yason-stock-quotes-parse (quote-string)
  "Reads a JSON string assumed to be Yahoo stock information and
returns an a-list of its data"
  (let ((results (gethash
                  "quote"
                  (gethash
                   "results"
                   (gethash
                    "query"
                    (yason:parse quote-string))))))
    (if (listp results)
        (map 'list #'parse-hashtable results)
        (parse-hashtable results))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(defun yason-quant-parse (data-string)
  "Reads a JSON string assumed to be data from Yahoo.finance.quant and
returns a hash-table of its data. \"TwoMonthsAgo\" is known to map to
a HTML string sometimes."
  (gethash
   "stock"
   (gethash
    "results"
    (gethash "query"
             (yason:parse data-string)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; modes of operation
(defparameter *historical-modes*
  '((:daily . "d")
    (:weekly ."w")
    (:monthly . "m")
    (:dividends_only . "v"))
  "Keys into historical quotes")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Mooched from Ram Krishnan's public post on
;; lispservice.posterous.com
(defun safely-read-from-string (str &rest read-from-string-args)
  "Read an expression from the string STR, with *READ-EVAL* set to
NIL. Any unsafe expressions will be replaced by NIL in the resulting
S-Expression."
  (let ((*read-eval* nil))
    (ignore-errors
      (apply 'read-from-string str read-from-string-args))))



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(defun request-csv-historical-stock (symbol-string url historical-type start-date end-date)
  "Core reading function for reading historical data"
  (labels ((month (date-list) (1- (first date-list)))
           (day (date-list)   (second date-list))
           (year (date-list)  (third date-list)))
    (let ((request-params
           ;;Params specified by Yahoo...
           '("s" "d" "e" "f" "g" "a" "b" "c" "ignore"))
          (param-values
           (mapcar
            #'to-s
            (list
             symbol-string
             (month end-date)
             (day end-date)
             (year end-date)
             (cdr (assoc historical-type *historical-modes*))
             (month start-date)
             (day start-date)
             (year start-date)
             ".csv"))))

      (cl-csv:read-csv
       (drakma:http-request
        url
        :parameters
        (pairlis
         request-params
         param-values)
        :proxy *proxy*)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; read the ratio for split to lisp ratio
;; (example, 3:1 as 3/1)
(defun read-ratio-to-lisp (str)
  (let ((pos (position #\: str)))
   (if pos
    (replace str "/" :start1 pos :end1 (+ 1 pos))))
  (safely-read-from-string str))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Exported functions
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Proxy management.

(defmacro with-proxy ((proxy-value) &body body)
  "Binds `proxy-value` to *proxy* for the duration of the macro"
  `(let ((*proxy* ,proxy-value))
     (progn
       ,@body)))
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun current-data-cleanse (hash-table)
  (let ((newtable (make-hash-table :test #'equal)))
    (loop for key in (alexandria:hash-table-keys hash-table) do
      (setf (gethash (getassoc key +string-to-keyword-map+ :test #'string=)
                     newtable)
            (gethash key hash-table)))
    newtable))



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(defun read-current-company-info (symbol-list
                                  &key (proxy *proxy*))
  "Reads the current company info and returns it as an a-list"
  (let ((list-of-symbols (alexandria:ensure-list symbol-list)))
    (mapcar
     #'convert-stringy-table-to-keyword
     (alexandria:ensure-list
      (yason-quant-parse
       (with-proxy (proxy)
         (request-yql-quant-info list-of-symbols)))))))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(defun read-current-options (symbol-list &key (proxy *proxy*))
  "Takes one or more symbols and returns a list of option hash tables.

See yason-stock-options-parse for details on the data structure."
  (let ((list-of-symbols (alexandria:ensure-list symbol-list)))
    (yason-stock-options-parse
     (with-proxy (proxy)
       (request-yql-options-info list-of-symbols)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;Historical data URL
(defun read-historical-data (symbol-string start-date end-date
                             &key
                               (historical-type :daily)
                               (proxy *proxy*))

  "Start and end dates are 3-element lists mm/dd/yy
  Returns a list of hash tables. Keys are:
  Date Open High Low Close Volume Adj-Close"
  (let ((rows
         (with-proxy (proxy)
           (request-csv-historical-stock
            symbol-string
            "http://ichart.finance.yahoo.com/table.csv"
            historical-type
            start-date end-date))))

    (convert-from-column-strings
     (append (list (first rows))
             (loop for row in (rest rows)
                collect
                  (cons (car row)
                        (mapcar #'safely-read-from-string
                                (rest row))))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(defun read-historical-splits (symbol-string start-date end-date
                               &key
                                 (proxy *proxy*))
  "Start and end dates are 3-element lists mm/dd/yy
  Returns a list of hash tables. Keys are:
  Date Split"
  (let ((rows
         (with-proxy (proxy)
           (request-csv-historical-stock
           symbol-string
           "http://ichart.finance.yahoo.com/x"
           :dividends_only
           start-date end-date))))

    (convert-from-column-strings
     (append '(("Date" "Split"))
             (delete
              nil
              (loop for row in rows
                 collect
                   (when (string-equal (first row) "SPLIT")
                     (list
                      (format nil "~{~A~}"
                              (list
                               (subseq (second row) 0 4) "-"
                               (subseq (second row) 4 6) "-"
                               (subseq (second row) 6)))
                      (read-ratio-to-lisp (third row))))))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Kick these for a test
;;(cl-yahoo-finance:read-historical-data "GOOG"  '(1 1 2009) '(1 1 2010) :historical-type 'daily)
;;(cl-yahoo-finance:read-historical-data "GOOG"  '(1 1 2009) '(1 1 2010) :historical-type 'weekly)
;;(cl-yahoo-finance:read-historical-data "GOOG"  '(1 1 2009) '(1 1 2010) :historical-type 'monthly)
;;(cl-yahoo-finance:read-historical-data "IBM"  '(1 1 2009) '(1 1 2010) :historical-type 'dividends_only)
;;(cl-yahoo-finance:read-historical-splits "SLV"  '(1 1 1960) '(1 1 2012))
;;(cl-yahoo-finance:read-current-data '("GOOG"))
;;(cl-yahoo-finance:read-current-company-info '("GOOG" "V" "SLCA"))

;;; maps the yason over to the intern keywordsq
(defparameter +string-to-keyword-map+
  (pairlis
   '("PercentChange" "DividendYield" "StockExchange"
     "DaysValueChangeRealtime" "DaysValueChange" "YearRange"
     "HoldingsValueRealtime" "HoldingsValue" "Volume" "OneyrTargetPrice"
     "TickerTrend" "LastTradeTime" "ShortRatio" "SharesOwned" "Symbol"
     "PriceEPSEstimateNextYear" "PriceEPSEstimateCurrentYear" "PEGRatio"
     "PERatioRealtime" "DividendPayDate" "PERatio" "ExDividendDate"
     "PriceBook" "PriceSales" "ChangeinPercent" "PricePaid" "PreviousClose"
     "Open" "Notes" "Name" "PercentChangeFromFiftydayMovingAverage"
     "ChangeFromFiftydayMovingAverage"
     "PercentChangeFromTwoHundreddayMovingAverage"
     "ChangeFromTwoHundreddayMovingAverage" "TwoHundreddayMovingAverage"
     "FiftydayMovingAverage" "DaysRangeRealtime" "DaysRange" "LowLimit"
     "HighLimit" "LastTradePriceOnly" "LastTradeWithTime"
     "PercebtChangeFromYearHigh" "ChangeFromYearHigh"
     "ChangePercentRealtime" "LastTradeRealtimeWithTime"
     "PercentChangeFromYearLow" "ChangeFromYearLow" "EBITDA"
     "MarketCapRealtime" "MarketCapitalization" "OrderBookRealtime"
     "MoreInfo" "HoldingsGainRealtime" "HoldingsGainPercentRealtime"
     "HoldingsGain" "AnnualizedGain" "HoldingsGainPercent" "YearHigh"
     "YearLow" "DaysHigh" "DaysLow" "EPSEstimateNextQuarter"
     "EPSEstimateNextYear" "EPSEstimateCurrentYear"
     "ErrorIndicationreturnedforsymbolchangedinvalid" "EarningsShare"
     "TradeDate" "LastTradeDate" "DividendShare" "AfterHoursChangeRealtime"
     "ChangeRealtime" "Commission" "Change" "Change_PercentChange"
     "BookValue" "BidRealtime" "AskRealtime" "Bid" "AverageDailyVolume"
     "Ask" "symbol")
   '(:percent-change :dividend-yield :stock-exchange
     :days-value-change-realtime :days-value-change :year-range
     :holdings-value-realtime :holdings-value :volume :one-yr-target-price
     :ticker-trend :last-trade-time :short-ratio :shares-owned :symbol
     :price-eps-estimate-next-year :price-epsestimate-current-year :peg-ratio
     :pe-ratio-realtime :dividend-pay-date :pe-ratio :ex-dividend-date
     :price-book :price-sales :change-in-percent :price-paid :previous-close
     :open :notes :name :percent-change-from-fifty-day-moving-average
     :change-from-fifty-day-moving-average
     :percent-change-from-two-hundred-day-moving-average
     :change-from-two-hundred-day-moving-average :two-hundredday-moving-average
     :fiftyday-moving-average :days-range-realtime :days-range :low-limit
     :high-limit :last-trade-price-only :last-trade-with-time
     :percebt-change-from-year-high :change-from-year-high
     :change-percent-realtime :last-trade-realtime-with-time
     :percent-change-from-year-low :change-from-year-low :ebitda
     :market-cap-realtime :market-capitalization :order-book-realtime
     :more-info :holdings-gain-realtime :holdings-gain-percent-realtime
     :holdings-gain :annualized-gain :holdings-gain-percent :year-high
     :year-low :days-high :days-low
     :eps-estimate-next-quarter
     :eps-estimate-next-year :eps-estimate-current-year
     :error-indication-returned-for-symbol-changed-invalid :earnings-share
     :trade-date :last-trade-date :dividend-share :after-hours-change-realtime
     :change-realtime :commission :change :change-percent-change :book-value
     :bid-realtime :ask-realtime :bid :average-daily-volume :ask :symbol))
  "A-list mapping the strings returned by the YASON into keywords")




;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; hacks because the stock price YQL system seems overloaded.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; column-name . yahoo-identifier
;; yahoo uses these identifiers as ways to parse out meaning.
(defparameter *columns*
  '((:ask . "a")
    ;(average_daily_volume . "a2")
    ;(ask_size . "a5")
    (:bid . "b")
    ;(ask_real_time . "b2")
    ;(bid_real_time . "b3")
    ;(book_value . "b4")
    ;(bid_size . "b6")
    ;(chance_and_percent_change . "c")
    (:change . "c1")
    ;(comission . "c3")
    ;(change_real_time . "c6")
    ;(after_hours_change_real_time . "c8")
    (:dividend_per_share . "d")
    ;(last_trade_date . "d1")
    ;(trade_date . "d2")
    (:earnings_per_share . "e")
    ;(error_indicator . "e1")
    ;(eps_estimate_current_year . "e7")
    ;(eps_estimate_next_year . "e8")
    (:eps_estimate_next_quarter . "e9")
    ;(float_shares . "f6")
    (:low . "g")
    (:high . "h")
    (:low_52_weeks . "j")
    (:high_52_weeks . "k")
    ;(holdings_gain_percent . "g1")
    ;(annualized_gain . "g3")
    ;(holdings_gain . "g4")
    ;(holdings_gain_percent_realtime . "g5")
    ;(holdings_gain_realtime . "g6")
    ;(more_info . "i")
    ;(order_book . "i5")
    ;(market_capitalization . "j1")
    ;(market_cap_realtime . "j3")
    (:ebitda . "j4")
    ;(change_From_52_week_low . "j5")
    ;(percent_change_from_52_week_low . "j6")
    ;(last_trade_realtime_withtime . "k1")
    ;(change_percent_realtime . "k2")
    ;(last_trade_size . "k3")
    ;(change_from_52_week_high . "k4")
    ;(percent_change_from_52_week_high . "k5")
    ;(last_trade_with_time . "l")
    ;(last_trade_price . "l1")
    (:close . "l1")
    ;(high_limit . "l2")
    ;(low_limit . "l3")
    ;(days_range . "m")
    ;(days_range_realtime . "m2")
    ;(moving_average_50_day . "m3")
    ;(moving_average_200_day . "m4")
    ;(change_from_200_day_moving_average . "m5")
    ;(percent_change_from_200_day_moving_average . "m6")
    ;(change_from_50_day_moving_average . "m7")
    ;(percent_change_from_50_day_moving_average . "m8")
    (:name . "n")
    ;(notes . "n4")
    (:open . "o")
    (:previous_close . "p")
    ;(price_paid . "p1")
    ;(change_in_percent . "p2")
    ;(price_per_sales . "p5")
    ;(price_per_book . "p6")
    ;(ex_dividend_date . "q")
    (:pe_ratio . "p5")
    ;(dividend_pay_date . "r1")
    ;(pe_ratio_realtime . "r2")
    (:peg_ratio . "r5")
    ;(price_eps_estimate_current_year . "r6")
    ;(price_eps_Estimate_next_year . "r7")
    (:symbol . "s")
    ;(shares_owned . "s1")
    (:short_ratio . "s7")
    ;(last_trade_time . "t1")
    ;;(trade_links . "t6")          ;; Horks up the parsing
    ;(ticker_trend . "t7")
    ;(one_year_target_price . "t8")
    (:volume . "v")
    ;(holdings_value . "v1")
    ;(holdings_value_realtime . "v7")
    ;(weeks_range_52 . "w")
    ;(day_value_change . "w1")
    ;(day_value_change_realtime . "w4")
    ;(stock_exchange . "x")
    (:dividend_yield . "y"))
  "This a-list serves as keys for the Yahoo stock information for a
  given quote")
    ;(adjusted_close . nil))) ; this one only comes in historical quotes


(defparameter *float-columns*
  '(:dividend_yield
    :short_ratio
    :peg_ratio
    :pe_ratio
    :previous_close
    :previousclose
    :open
    :close
    :high_52_weeks
    :low_52_weeks
    :high
    :low
    :eps_estimate_next_quarter
    :earnings_per_share
    :dividend_per_share
    :change
    :bid
    :volume
    :ask
    :askrealtime
    :bidrealtime
    :dividendshare
    :earningsshare
    :fiftydaymovingaverage
    :twohundreddaymovingaverage
    :averagedailyvolume
    :oneyrtargetprice
    :pricesales
    :prevousclose
    :pricebook
    :bookvalue
    :pegratio
    :priceepsestimatecurrentyear
    :priceepsestimatenextyear
    :epsestimatecurrentyear
    :epsestimatenextyear
    :epsestimatenextquarter
    :epsestimatecurrentparter
    :lasttradepriceonly
    :changefromhigh
    :changefromyearhigh
    :dayslow
    :dayshigh
    :yearlow
    :yearhigh
    :changerealtime))

(defun parse-float (string)
  "Return a float read from string, and the index to the remainder of string."
  (multiple-value-bind (integer i)
      (parse-integer string :junk-allowed t)
    (cond
      ((or (<= (length string) i)
           (not (eq #\. (aref string i))))
       integer)
      ((<=  (length string) (1+ i))
       (coerce integer 'single-float))
      (t
       (multiple-value-bind (fraction j)
           (parse-integer string :start (+ i 1) :junk-allowed t)
         (values (float (+ integer (/ fraction (expt 10 (- j i 1))))) j))))))

(defun parse-entry (name string-value)
  "Convert the STRING-VALUE to a more helpful type.

Returns (values NEW-VALUE converted-p).  The second value will be true
if a conversion took place."
  (cond
    ((string= string-value "N/A")
     (values nil t))
    ((find name *float-columns*)
     (values (parse-float string-value) t))
    (t (values string-value nil))))

(defun parse-hashtable (table)
  "Clean and destringify entries in the hash table."
  (let ((kw (find-package "KEYWORD")))
    (maphash (lambda (k v)
               (multiple-value-bind (new-val changed)
                   (parse-entry (intern (string-upcase  k) kw)
                                v)
                 (when changed
                   (setf (gethash k table) new-val))))
             table)
    table))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(defun read-current-data-from-csv (symbol-or-symbol-list
                                   &key
                                     (proxy *proxy*))
  "Pass in a list of symbols in strings; get a list of a-lists out.
Useful if YQL bails on us"

  (let*
      ((columnnames
        (mapcar #'car
                *columns*))
       (columnlist
        (format nil "~{~a~}"
                (mapcar #'cdr
                        *columns*)))
       (gathered-symbol-list
        (format nil "~{~a~^+~}"
                (alexandria:ensure-list symbol-or-symbol-list)))
       (rows
        (cl-csv:read-csv
         (babel:octets-to-string
          (drakma:http-request
           "http://finance.yahoo.com/d/quotes.csv"
           :method :get
           :parameters
           (list* (cons "s" gathered-symbol-list)
                  (cons "f" columnlist)
                  '(("e" . ".csv")))
           :proxy proxy)))))

    ;; Create the alist(s)
    (loop for row in rows
       collect
         (let ((hash (make-hash-table)))
           (map 'list #'(lambda (key value)
                          (setf (gethash key hash)
                                (parse-entry key value)))
                columnnames row)
           hash))))


(defun read-current-data (symbol-or-symbol-list
                          &key
                            (proxy *proxy*))
  "Returns a list of hash tables"
  (read-current-data-from-csv symbol-or-symbol-list
                              :proxy proxy))
