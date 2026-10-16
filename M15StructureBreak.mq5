//+------------------------------------------------------------------+
//| M15 Structure Break + FVG Midpoint EA                            |
//| Educational template. Test in Strategy Tester/demo before live.   |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "M15 HL/LH structure break, nearest post-break FVG midpoint, 1:1 RR"

#include <Trade/Trade.mqh>
CTrade trade;

//+------------------------------------------------------------------+
//| User inputs                                                      |
//+------------------------------------------------------------------+
input group "=== Trading Settings ==="
input ENUM_TIMEFRAMES InpTimeframe            = PERIOD_M15; // Timeframe (M5, M15, H1, etc.)
input double          InpLots                 = 0.1;        // Lot Size
input double          InpOrderExpirationHours = 2.0;        // Pending order expiration (hours, 0=disabled)
input ulong           InpMagic                = 15102026;   // Magic Number

input group "=== Strategy Parameters ==="
input int    InpSwingStrength        = 2;       // confirmed pivot bars on each side
input int    InpScanBars             = 250;     // history scanned for swings
input int    InpFvgScanBars          = 80;      // bars scanned for post-break FVG
input int    InpSLBufferPoints       = 20;      // buffer beyond swing extreme
input int    InpMaxSpreadPoints      = 0;       // 0 = disabled
input bool   InpOnePositionAtATime   = true;    // One position or order at a time
input bool   InpOneSetupPerBreak     = true;    // One setup per break
input bool   InpDrawZones            = true;    // Draw zones on chart
input bool   InpShowDashboard        = true;    // Show status dashboard on chart/tester
input bool   InpAllowBuy             = true;    // Allow Buy setups
input bool   InpAllowSell            = true;    // Allow Sell setups

ENUM_TIMEFRAMES TF = PERIOD_M15;

datetime g_lastBarTime = 0;
datetime g_lastSellBreakTime = 0;
datetime g_lastBuyBreakTime  = 0;
bool     g_sellSetupActive   = false;
bool     g_buySetupActive    = false;
datetime g_activeSellBreak  = 0;
datetime g_activeBuyBreak   = 0;
double   g_activeSellSLBase = 0.0;
double   g_activeBuySLBase  = 0.0;

struct FvgZone
{
   bool     valid;
   bool     bullish;
   double   lower;
   double   upper;
   datetime formed;
};

struct Pivot
{
   int      shift;
   double   price;
   datetime time;
};

string Prefix()
{
   string tfName = StringSubstr(EnumToString(TF), 7);
   return "SFVG_" + tfName + "_" + IntegerToString((long)InpMagic) + "_";
}

bool IsNewBar()
{
   datetime t = iTime(_Symbol, TF, 0);
   if(t == 0) return false;
   if(t != g_lastBarTime)
   {
      g_lastBarTime = t;
      return true;
   }
   return false;
}

bool IsNewM15Bar()
{
   return IsNewBar();
}

bool SpreadAllowed()
{
   if(InpMaxSpreadPoints <= 0) return true;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0 || bid <= 0) return false;
   return ((ask - bid) / _Point <= InpMaxSpreadPoints);
}

bool HasOurPositionOrOrder()
{
   if(!InpOnePositionAtATime) return false;

   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic)
         return true;
   }

   for(int j = OrdersTotal() - 1; j >= 0; --j)
   {
      ulong ticket = OrderGetTicket(j);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) == _Symbol &&
         (ulong)OrderGetInteger(ORDER_MAGIC) == InpMagic)
         return true;
   }
   return false;
}

bool IsPivotLow(const MqlRates &r[], int shift, int strength, int total)
{
   if(shift - strength < 1 || shift + strength >= total) return false;
   double p = r[shift].low;
   for(int k = 1; k <= strength; ++k)
   {
      if(r[shift-k].low <= p) return false; // newer bars
      if(r[shift+k].low <  p) return false; // older bars
   }
   return true;
}

bool IsPivotHigh(const MqlRates &r[], int shift, int strength, int total)
{
   if(shift - strength < 1 || shift + strength >= total) return false;
   double p = r[shift].high;
   for(int k = 1; k <= strength; ++k)
   {
      if(r[shift-k].high >= p) return false;
      if(r[shift+k].high >  p) return false;
   }
   return true;
}

int GetLastTwoPivots(const MqlRates &r[], int total, bool wantLow, Pivot &newest, Pivot &previous)
{
   int found = 0;
   int maxShift = MathMin(InpScanBars, total - InpSwingStrength - 2);
   for(int s = InpSwingStrength + 1; s <= maxShift; ++s)
   {
      bool ok = wantLow ? IsPivotLow(r, s, InpSwingStrength, total)
                        : IsPivotHigh(r, s, InpSwingStrength, total);
      if(!ok) continue;

      Pivot p;
      p.shift = s;
      p.price = wantLow ? r[s].low : r[s].high;
      p.time  = r[s].time;

      if(found == 0) { newest = p; found = 1; }
      else { previous = p; return 2; }
   }
   return found;
}

double HighestHighBetween(const MqlRates &r[], int fromShift, int toShift)
{
   double v = -DBL_MAX;
   int a = MathMax(1, MathMin(fromShift, toShift));
   int b = MathMax(fromShift, toShift);
   for(int i = a; i <= b; ++i) v = MathMax(v, r[i].high);
   return v;
}

double LowestLowBetween(const MqlRates &r[], int fromShift, int toShift)
{
   double v = DBL_MAX;
   int a = MathMax(1, MathMin(fromShift, toShift));
   int b = MathMax(fromShift, toShift);
   for(int i = a; i <= b; ++i) v = MathMin(v, r[i].low);
   return v;
}

void DrawHLine(string name, double price, color clr, ENUM_LINE_STYLE style=STYLE_SOLID)
{
   if(!InpDrawZones) return;
   name = Prefix() + name;
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
   ObjectSetDouble(0, name, OBJPROP_PRICE, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
}

void DrawFvg(string name, datetime start, double lower, datetime end, double upper, color clr)
{
   if(!InpDrawZones) return;
   name = Prefix() + name;
   if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
   ObjectCreate(0, name, OBJ_RECTANGLE, 0, start, upper, end, lower);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FILL, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
}

bool FindNearestFVG(const MqlRates &r[], int total, datetime breakTime, bool bullish, FvgZone &zone)
{
   zone.valid = false;
   int limit = MathMin(InpFvgScanBars, total - 3);

   // In series arrays, shift 1 is the last closed candle. Scanning upward
   // finds the newest eligible FVG first: the nearest/latest zone.
   for(int s = 1; s <= limit; ++s)
   {
      // Three candles in chronological order: older=A (s+2), middle=B (s+1), newer=C (s)
      if(r[s].time <= breakTime) continue;

      double lower = 0, upper = 0;
      bool isFvg = false;

      if(bullish)
      {
         // Bullish FVG: high of A < low of C
         if(r[s+2].high < r[s].low)
         {
            lower = r[s+2].high;
            upper = r[s].low;
            isFvg = true;
         }
      }
      else
      {
         // Bearish FVG: low of A > high of C
         if(r[s+2].low > r[s].high)
         {
            lower = r[s].high;
            upper = r[s+2].low;
            isFvg = true;
         }
      }

      if(!isFvg || upper <= lower) continue;

      // Ignore a zone that has already been fully crossed by current price.
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(!bullish && ask > upper) continue;
      if( bullish && bid < lower) continue;

      zone.valid   = true;
      zone.bullish = bullish;
      zone.lower   = lower;
      zone.upper   = upper;
      zone.formed  = r[s].time;
      return true;
   }
   return false;
}

double NormalizePrice(double price)
{
   return NormalizeDouble(price, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
}

double NormalizeLots(double lots)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0) return lots;
   lots = MathMax(minLot, MathMin(maxLot, lots));
   lots = MathFloor(lots / step) * step;
   int digits = 2;
   if(step < 0.01) digits = 3;
   if(step < 0.001) digits = 4;
   return NormalizeDouble(lots, digits);
}

bool PlaceFvgLimit(bool bullish, const FvgZone &zone, double swingExtreme, datetime breakTime)
{
   if(HasOurPositionOrOrder() || !SpreadAllowed()) return false;

   double entry = (zone.lower + zone.upper) / 2.0;
   double sl = bullish ? swingExtreme - InpSLBufferPoints * _Point
                       : swingExtreme + InpSLBufferPoints * _Point;
   entry = NormalizePrice(entry);
   sl = NormalizePrice(sl);

   if((bullish && sl >= entry) || (!bullish && sl <= entry)) return false;

   double risk = MathAbs(entry - sl);
   if(risk <= 0) return false;
   double tp = bullish ? entry + risk : entry - risk;
   tp = NormalizePrice(tp);

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = stopsLevel * _Point;

   // A Buy Limit must be below Ask; a Sell Limit must be above Bid.
   if(bullish)
   {
      if(entry >= ask || (ask - entry) < minDist) return false;
   }
   else
   {
      if(entry <= bid || (entry - bid) < minDist) return false;
   }

   // SL/TP validity relative to entry
   if(MathAbs(entry - sl) < minDist || MathAbs(tp - entry) < minDist) return false;

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(10);
   double lots = NormalizeLots(InpLots);
   string tfName = StringSubstr(EnumToString(TF), 7);
   string comment = StringFormat("%s %s FVG 50%%", tfName, bullish ? "Bull" : "Bear");

   ENUM_ORDER_TYPE_TIME orderTimeType = ORDER_TIME_GTC;
   datetime expirationTime = 0;
   if(InpOrderExpirationHours > 0)
   {
      long expFlags = SymbolInfoInteger(_Symbol, SYMBOL_EXPIRATION_MODE);
      if((expFlags & SYMBOL_EXPIRATION_SPECIFIED) != 0)
      {
         orderTimeType = ORDER_TIME_SPECIFIED;
         expirationTime = TimeCurrent() + (datetime)(InpOrderExpirationHours * 3600);
      }
   }

   bool sent = false;
   if(bullish)
      sent = trade.BuyLimit(lots, entry, _Symbol, sl, tp, orderTimeType, expirationTime, comment);
   else
      sent = trade.SellLimit(lots, entry, _Symbol, sl, tp, orderTimeType, expirationTime, comment);

   if(sent)
   {
      string side = bullish ? "BUY" : "SELL";
      Print(side, " limit placed. Entry=", entry, " SL=", sl, " TP=", tp,
            " FVG[", zone.lower, ", ", zone.upper, "] break=", TimeToString(breakTime));
      DrawFvg((bullish ? "BullFVG_" : "BearFVG_") + TimeToString(zone.formed, TIME_DATE|TIME_MINUTES),
              zone.formed, zone.lower, TimeCurrent() + 15*PeriodSeconds(TF), zone.upper,
              bullish ? clrDodgerBlue : clrTomato);
      DrawHLine((bullish ? "BuyEntry_" : "SellEntry_") + TimeToString(zone.formed, TIME_MINUTES), entry,
                bullish ? clrDodgerBlue : clrTomato, STYLE_DASH);
      DrawHLine((bullish ? "BuySL_" : "SellSL_") + TimeToString(zone.formed, TIME_MINUTES), sl, clrRed);
      DrawHLine((bullish ? "BuyTP_" : "SellTP_") + TimeToString(zone.formed, TIME_MINUTES), tp, clrLimeGreen);
   }
   else
   {
      Print("Order rejected. Retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
   }
   return sent;
}

void ProcessNewClosedBar()
{
   MqlRates r[];
   ArraySetAsSeries(r, true);
   int need = MathMax(InpScanBars + InpSwingStrength + 10, InpFvgScanBars + 10);
   int copied = CopyRates(_Symbol, TF, 0, need, r);
   if(copied < 20) return;

   // Last two confirmed swing lows/highs.
   Pivot low1, low2, high1, high2;
   int lows = GetLastTwoPivots(r, copied, true, low1, low2);
   int highs = GetLastTwoPivots(r, copied, false, high1, high2);
   if(lows < 2 || highs < 2) return;

   double close1 = r[1].close; // last fully closed M15 candle
   datetime breakTime = r[1].time;

   // If a structure break was confirmed on an earlier candle, wait for the
   // nearest/newest valid FVG formed after that break, then place a midpoint limit.
   if(g_sellSetupActive)
   {
      FvgZone z;
      if(FindNearestFVG(r, copied, g_activeSellBreak, false, z))
      {
         if(PlaceFvgLimit(false, z, g_activeSellSLBase, g_activeSellBreak))
            g_sellSetupActive = false;
      }
   }
   if(g_buySetupActive)
   {
      FvgZone z;
      if(FindNearestFVG(r, copied, g_activeBuyBreak, true, z))
      {
         if(PlaceFvgLimit(true, z, g_activeBuySLBase, g_activeBuyBreak))
            g_buySetupActive = false;
      }
   }

   // SELL: newest confirmed swing low is a Higher Low than the prior swing low,
   // and the last closed candle closes below that HL. Keep setup active while
   // waiting for an FVG to form on the post-break leg.
   if(InpAllowSell && !g_sellSetupActive &&
      low1.price > low2.price && close1 < low1.price &&
      breakTime != g_lastSellBreakTime)
   {
      int from = low1.shift;
      for(int s = low1.shift + 1; s < copied - InpSwingStrength; ++s)
      {
         if(IsPivotHigh(r, s, InpSwingStrength, copied)) { from = s; break; }
      }
      g_activeSellSLBase = HighestHighBetween(r, 1, from);
      g_activeSellBreak = breakTime;
      g_sellSetupActive = true;
      g_lastSellBreakTime = breakTime;
      DrawHLine("BrokenHL_" + TimeToString(breakTime, TIME_MINUTES), low1.price, clrOrange, STYLE_DASH);
      Print("SELL structure break confirmed. Waiting for bearish FVG after ",
            TimeToString(breakTime));
   }

   // BUY: newest confirmed swing high is a Lower High than prior swing high,
   // and the last closed candle closes above that LH.
   if(InpAllowBuy && !g_buySetupActive &&
      high1.price < high2.price && close1 > high1.price &&
      breakTime != g_lastBuyBreakTime)
   {
      int from = high1.shift;
      for(int s = high1.shift + 1; s < copied - InpSwingStrength; ++s)
      {
         if(IsPivotLow(r, s, InpSwingStrength, copied)) { from = s; break; }
      }
      g_activeBuySLBase = LowestLowBetween(r, 1, from);
      g_activeBuyBreak = breakTime;
      g_buySetupActive = true;
      g_lastBuyBreakTime = breakTime;
      DrawHLine("BrokenLH_" + TimeToString(breakTime, TIME_MINUTES), high1.price, clrAqua, STYLE_DASH);
      Print("BUY structure break confirmed. Waiting for bullish FVG after ",
            TimeToString(breakTime));
   }
}

void CheckPendingOrdersExpiration()
{
   if(InpOrderExpirationHours <= 0) return;

   datetime now = TimeCurrent();
   for(int j = OrdersTotal() - 1; j >= 0; --j)
   {
      ulong ticket = OrderGetTicket(j);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if((ulong)OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;

      datetime setupTime = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
      if(setupTime > 0 && now >= setupTime && (now - setupTime) >= (datetime)(InpOrderExpirationHours * 3600))
      {
         Print("Pending order #", ticket, " expired (> ", DoubleToString(InpOrderExpirationHours, 2),
               " hours). Deleting...");
         if(!trade.OrderDelete(ticket))
         {
            Print("Failed to delete expired order #", ticket,
                  ". Retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
         }
      }
   }
}

void UpdateDashboard()
{
   if(!InpShowDashboard) return;

   string tfName = StringSubstr(EnumToString(TF), 7);
   int openOrders = 0;
   int openPos = 0;

   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong posTicket = PositionGetTicket(i);
      if(posTicket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic)
         openPos++;
   }
   for(int j = OrdersTotal() - 1; j >= 0; --j)
   {
      ulong ordTicket = OrderGetTicket(j);
      if(ordTicket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) == _Symbol && (ulong)OrderGetInteger(ORDER_MAGIC) == InpMagic)
         openOrders++;
   }

   string state = "Scanning structure break";
   if(g_sellSetupActive) state = "Sell break confirmed -> Waiting for Bear FVG";
   else if(g_buySetupActive) state = "Buy break confirmed -> Waiting for Bull FVG";
   else if(openOrders > 0) state = "Pending Limit Order placed (Waiting for fill)";
   else if(openPos > 0) state = "Trade filled / Position open";

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spread = (ask > 0 && bid > 0) ? (ask - bid) / _Point : 0;

   string dash = StringFormat(
      "=========================================\n" +
      "   Structure Break + FVG EA\n" +
      "=========================================\n" +
      " Symbol:           %s\n" +
      " Timeframe:        %s\n" +
      " Lot Size:         %.2f\n" +
      " Order Expiration: %.1f Hours\n" +
      " Magic Number:     %I64u\n" +
      " Current Spread:   %.1f pts\n" +
      " State:            %s\n" +
      " Pending Orders:   %d\n" +
      " Open Positions:   %d\n" +
      "=========================================",
      _Symbol,
      tfName,
      InpLots,
      InpOrderExpirationHours,
      InpMagic,
      spread,
      state,
      openOrders,
      openPos
   );

   Comment(dash);
}

int OnInit()
{
   TF = (InpTimeframe == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)_Period : InpTimeframe;
   trade.SetExpertMagicNumber(InpMagic);
   g_lastBarTime = iTime(_Symbol, TF, 0);
   Print("Structure + FVG EA initialized on ", _Symbol,
         " | TF: ", EnumToString(TF),
         " | Lots: ", DoubleToString(InpLots, 2),
         " | Expiry: ", DoubleToString(InpOrderExpirationHours, 1), " hrs");
   UpdateDashboard();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   Comment("");
}

void OnTick()
{
   CheckPendingOrdersExpiration();
   UpdateDashboard();

   if(IsNewBar())
      ProcessNewClosedBar();
}
//+------------------------------------------------------------------+
